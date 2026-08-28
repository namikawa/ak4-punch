# frozen_string_literal: true

require "date"

module Ak4Punch
  # 「対象日」と「取得済みイベント」から、その日の出勤・退勤の目標時刻と判断根拠を計算する純ロジック。
  # 可変状態を持たない（config と logger だけを持つ）ため、同じ入力からは必ず同じ DayPlan を返す。
  #
  # 呼び出し元は2つ:
  #   - Daemon … 当日計画の作成・定期再取得・退勤の打刻直前チェック
  #     （計算結果を打刻計画・休暇スナップショットへ反映するのは Daemon の責務）
  #   - CLI#plan … `punch plan` のドライラン表示
  #
  # 計算の骨子（AKASHI は記録時刻＝リクエスト到着時刻のため「打刻したい時刻にPOST」する）:
  #   - 出勤 = 打刻締切 − 揺らぎ（締切 = min(所定出勤時刻+ウィンドウ, 最初の業務イベントの開始)。
  #     予定の開始までに打刻を済ませる）。目標は朝の起床時刻（morning_wake_at）でクランプする。
  #   - 退勤 = 基準時刻 + 揺らぎ（基準 = max(所定退勤時刻, 最後の業務イベントの終了)）
  #   - 揺らぎは日毎・kind毎に固定した秒数（従来のウィンドウ機構を織込）。出勤は締切から手前へ、
  #     退勤は基準から後ろへずらすため、向きが逆になる。日付と kind から決定論的に決まるので、
  #     定期再取得のたびに目標がブレることはない。
  #   - カレンダーの休暇イベント（タイトルがキーワードに部分一致・時間の閾値なし）は
  #     「その時間帯は勤務しない」の意味で扱う（LeaveSchedule）。業務イベントの判定からは常に
  #     除外し、上で決めた出勤締切・退勤基準がその時間帯に入っていたら休暇の外へ押し出す
  #     （出勤は休暇の終了へ後ろ倒し／退勤は休暇の開始へ前倒し）。押し出しの結果
  #     「出勤締切 >= 退勤基準」になった日は勤務時間ゼロ＝全休（DayPlan#full_leave?）。
  class DayPlanner
    # 揺らぎ乱数のシードを in/out で分けるための salt。
    KIND_SALT = { in: 0x1111, out: 0x2222 }.freeze

    # 出勤側の計画結果。
    #   target:       打刻目標（締切 − 揺らぎ。朝の起床時刻でクランプ）
    #   deadline:     打刻締切（休暇の押し出し適用後）
    #   plan:         ClockInPlanner::Plan（連動OFF・取得失敗時は nil）
    #   summary:      判断根拠の要約（ログ用）
    #   error:        sukesan 取得失敗のメッセージ（正常時 nil）
    #   leave_shifts: 休暇による押し出しの記録（LeaveSchedule::Shift 配列）
    ClockInResult = Struct.new(:target, :deadline, :plan, :summary, :error, :leave_shifts,
                               keyword_init: true)

    # 退勤側の計画結果。出勤の deadline（締切＝打刻の上限）に対して base（基準＝下限）を持つ。
    # 他のフィールドの意味は ClockInResult と同じ。
    ClockOutResult = Struct.new(:target, :base, :plan, :summary, :error, :leave_shifts,
                                keyword_init: true)

    # 1日分の打刻計画（出勤・退勤・その日の休暇）。
    DayPlan = Struct.new(:date, :leaves, :clock_in, :clock_out, keyword_init: true) do
      # 休暇の押し出し後に「出勤締切 >= 退勤基準」＝勤務時間ゼロになったか（＝全休）。
      # 終日休暇（00:00〜翌00:00）もこの判定で全休になるため、全休は特別ルールではなく帰結。
      # 判定は揺らぎを足す前の締切・基準で行う（揺らぎの向きで勤務時間の有無が変わらないように）。
      # 休暇イベントが1件もない日は判定しない（所定退勤 <= 所定出勤 という設定ミスのときに
      # 「全休」として黙って打刻を止めないため）。
      def full_leave? = leaves.any? && clock_in.deadline >= clock_out.base

      # kind に対応する「休暇を反映して計算した目標」。
      def target_for(kind) = kind == :in ? clock_in.target : clock_out.target
    end

    def initialize(config:, logger:)
      @config = config
      @logger = logger
    end

    # 指定日の打刻計画を組み立てて DayPlan を返す。
    # events: 取得済みイベント配列（nil = カレンダー連動OFF、または取得失敗）
    # error:  sukesan 取得失敗のメッセージ（正常時 nil）
    # sukesan の取得は呼び出し側が1回だけ行い、休暇・出勤・退勤の計画で共用する（二重 fetch 回避）。
    def call(date:, events:, error: nil)
      leaves = leave_schedule(events, date)
      clock_in = clock_in_result(date: date, events: events, leaves: leaves, error: error)
      clock_out = clock_out_result(date: date, events: events, leaves: leaves, error: error)
      DayPlan.new(date: date, leaves: leaves, clock_in: clock_in, clock_out: clock_out)
    end

    # その日の朝に Mac を起こす時刻。出勤アンカーの下限（ClockInPlanner の earliest_at）も
    # これと同じ値を使い、「Mac が確実に起きている時刻以降に始まる予定しかアンカーにしない」
    # という不変条件を1本で保つ。
    #   daemon.morning_wake_at 設定あり → min(その時刻, 所定出勤時刻)
    #   未設定                          → 所定出勤時刻
    # min を取るのは、morning_wake_at を所定より遅く設定してしまっても
    # 従来より起床が遅くならない（出勤に間に合う）ようにするため。
    # 未設定時に nil（下限なし）にしないのは、深夜の予定（例 00:30）をアンカーにしてしまい、
    # 寝ている Mac では grace 超過で出勤が打刻されず、起きていれば 00:29 に打刻される、
    # という従来（所定＋揺らぎ固定）より危険な挙動になるため。
    # 代償として morning_wake_at 未設定だと下限＝所定出勤時刻になり、所定より前に始まる
    # 予定はアンカーにならない（＝出勤のカレンダー連動が実質無効。この設定が有効化スイッチを兼ねる）。
    # 出勤目標は clock_in_result でこの時刻にクランプするため、これを下回らない。
    def morning_wake_at(date)
      default = clock_in_default_at(date)
      hhmm = @config.daemon_morning_wake_at
      return default if hhmm.nil?

      [time_on(date, hhmm), default].min
    end

    private

    # 出勤の目標時刻を計算する。events は取得済みイベント配列
    # （nil は未取得＝連動OFF、または取得失敗。失敗時は error にメッセージ）。
    # leaves は当日の休暇イベント（LeaveSchedule）。業務イベントの判定から休暇を外し、
    # 決めた締切が休暇の時間帯に入っていたら休暇の外（終了時刻）へ後ろ倒しする。
    #
    # 出勤は「締切ベース」で決める: 打刻締切 = min(所定出勤時刻+ウィンドウ, 最初の業務イベント開始)、
    # 目標 = 締切 − 揺らぎ（朝の起床時刻でクランプ）。
    # 予定なしの日の範囲（所定〜所定+ウィンドウ）は従来と変わらない。
    def clock_in_result(date:, events:, leaves:, error: nil)
      default = clock_in_deadline_at(date)
      earliest = morning_wake_at(date) # アンカーの下限 兼 目標のクランプ下限
      plan = nil

      if !@config.calendar_enabled
        # 連動OFFなら所定の締切（−揺らぎ）を使う（sukesan にはアクセスしない前提）。
        deadline = default
        summary = "カレンダー連動OFF（所定時刻）"
        error = nil
      elsif events.nil?
        @logger.warn("sukesan からのイベント取得に失敗しました（#{error}）。所定出勤時刻へフォールバックします。")
        deadline = default
        summary = "sukesan 障害のため所定時刻へフォールバック"
      else
        plan = ClockInPlanner.new(exclude_keywords: @config.calendar_clock_in_exclude_keywords)
                             .plan(events: leaves.work_events, date: date, default_deadline: default,
                                   earliest_at: earliest)
        deadline = plan.deadline_at
        summary =
          if plan.source == :calendar
            "採用: #{start_event_label(plan.adopted_event)}"
          else
            "所定時刻（#{plan.fallback_reason}）"
          end
        error = nil
      end

      # 締切が休暇の時間帯に入っていたら休暇の外へ後ろ倒しする（午前休の日に出勤が
      # 休暇明けになる経路）。連動OFF・取得失敗時は休暇が空なので no-op。
      deadline, shifts = leaves.push_after(deadline)
      summary = "#{summary}／#{shifts.map(&:label).join('、')}" unless shifts.empty?

      ClockInResult.new(target: in_target_at(deadline, date, earliest), deadline: deadline,
                        plan: plan, summary: summary, error: error, leave_shifts: shifts)
    end

    # 出勤の目標時刻 = 締切 − 揺らぎ。ただし朝の起床時刻より前には出さない（クランプ）。
    # 締切は下限（＝起床時刻）ちょうどまで下がりうるため、そこから揺らぎを引くと起床前になり、
    # 「ウィンドウ − wake_lead > grace」の設定では起床した時点で既に grace 超過＝出勤が
    # 恒久スキップになってしまう。クランプは連動OFF・取得失敗の経路にも一律で適用する
    # （それらは締切が所定+ウィンドウなので実質 no-op）。
    def in_target_at(deadline, date, earliest)
      [apply_jitter_before(deadline, date, :in), earliest].max
    end

    # 退勤の目標時刻を計算する。events は取得済みイベント配列
    # （nil は未取得＝連動OFF、または取得失敗。失敗時は error にメッセージ）。
    # leaves は当日の休暇イベント（LeaveSchedule）。業務イベントの判定から休暇を外し、
    # 決めた基準が休暇の時間帯に入っていたら休暇の外（開始時刻）へ前倒しする。
    def clock_out_result(date:, events:, leaves:, error: nil)
      default = clock_out_default_at(date)
      plan = nil

      if !@config.calendar_enabled
        # 連動OFFなら所定時刻（+揺らぎ）を使う（sukesan にはアクセスしない前提）。
        base = default
        summary = "カレンダー連動OFF（所定時刻）"
        error = nil
      elsif events.nil?
        @logger.warn("sukesan からのイベント取得に失敗しました（#{error}）。所定退勤時刻へフォールバックします。")
        base = default
        summary = "sukesan 障害のため所定時刻へフォールバック"
      else
        plan = ClockOutPlanner.new(exclude_keywords: @config.calendar_exclude_keywords)
                              .plan(events: leaves.work_events, date: date, default_clock_out: default)
        base = plan.target_at
        summary =
          if plan.source == :calendar
            "採用: #{event_label(plan.adopted_event)}"
          else
            "所定時刻（#{plan.fallback_reason}）"
          end
        error = nil
      end

      # 基準が休暇の時間帯に入っていたら休暇の外へ前倒しする（午後休の日に退勤が
      # 休暇の開始になる経路）。基準を先に決めてから押し出すのが肝で、休暇の後ろに
      # 業務イベントがある日（中抜け）は基準がそのイベントの終了になり押し出しは起きない。
      base, shifts = leaves.push_before(base)
      summary = "#{summary}／#{shifts.map(&:label).join('、')}" unless shifts.empty?

      jittered = apply_jitter(base, date, :out)
      target = out_target_at(jittered, base, date)
      summary = "#{summary}／揺らぎ後 #{hhmm(jittered, base: base)} が翌日になるため基準時刻に戻す" if target != jittered

      ClockOutResult.new(target: target, base: base, plan: plan,
                         summary: summary, error: error, leave_shifts: shifts)
    end

    # 退勤の目標時刻 = 基準 + 揺らぎ。ただし揺らぎ後が翌日に出る日は揺らぎを落として基準そのものにする。
    # 目標が翌日に出ると、日付が変わった最初の tick で当日の計画が破棄される（start_new_day）ため
    # その日の退勤は必ず未打刻になる。基準（base）が当日内でも「基準+揺らぎ」は翌日に跨りうる
    # （実測: 23:59 終了のイベント + clock_out_window 5分 で 12日サンプル中8日が翌日になった。
    #  例 2026-07-10 は揺らぎ183秒で翌日 00:02:03）。設定由来の跨ぎは Config が起動時に弾くが、
    # カレンダー由来はここで押さえる必要がある。
    #
    # 「当日内に収める」（23:59:59 で頭を押さえる）のでは足りない。Daemon#fire_due_punches は
    # 目標到達後（now >= target）に発火し、tick は daemon.tick_seconds（既定30秒）間隔なので、
    # 目標が日付変更の直前だと発火機会がほぼ無く、tick の位相次第で結局打刻されない
    # （23:59:59 なら窓は1秒＝30通りの位相のうち1通りだけ。基準 23:59:00 に戻せば窓は60秒になり
    #  どの位相でも1回は tick が入る）。揺らぎの忠実さより「そもそも打刻されること」を優先する。
    #
    # 基準は「最終業務イベントの終了（または所定退勤時刻）」なので、そこへ落としても
    # target >= base（退勤基準より前には打刻しない）は等号で保たれる。揺らぎは日付と kind から
    # 決まる決定論的な値のままで、この分岐も基準が同じなら同じ結果になるため
    # 「再取得のたびに目標がブレない」不変条件も壊さない。
    # 基準自体が 23:59:59 付近だと窓は縮むが、それはイベントの終了時刻そのものが
    # 日付変更の直前という打つ手のない縮退ケース。
    def out_target_at(jittered, base, date) = jittered.to_date == date ? jittered : base

    # 基準時刻に「日毎・kind毎に固定した揺らぎ秒」を足す（退勤: 基準は下限なので後ろへずらす）。
    def apply_jitter(base_time, date, kind) = base_time + jitter_seconds(date, kind)

    # 締切から「日毎・kind毎に固定した揺らぎ秒」を引く（出勤: 基準は締切なので手前へずらす）。
    def apply_jitter_before(deadline, date, kind) = deadline - jitter_seconds(date, kind)

    # 日毎・kind毎に固定した揺らぎ秒。定期再取得のたびに目標がブレないよう、
    # 日付とkindから決定論的に決める（このシードの導出は変えないこと＝目標時刻を動かさないこと）。
    # 起点は「その日の JST 午前0時」。Date#to_time はローカルタイムゾーン依存なので使わない
    # （TZ が JST 以外の環境では同じ日でも別の揺らぎになり、「日付・時刻ロジックはすべて JST 基準」
    #  という不変条件から外れる。旅行先で Mac の TZ を変えると当日の目標が動く／CI が落ちる）。
    # JST 環境では Date#to_time と同値なので、既存の目標時刻は変わらない（366日分で実測確認済み）。
    def jitter_seconds(date, kind)
      window = kind == :in ? @config.clock_in_window : @config.clock_out_window
      return 0 unless window.positive?

      day_start = Time.new(date.year, date.month, date.day, 0, 0, 0, Ak4Punch::JST)
      seed = day_start.to_i ^ KIND_SALT.fetch(kind)
      Random.new(seed).rand(0..(window * 60))
    end

    def clock_in_default_at(date) = time_on(date, @config.clock_in_time)
    def clock_out_default_at(date) = time_on(date, @config.clock_out_time)

    # 所定の出勤締切 = 所定出勤時刻 + ウィンドウ分。カレンダー由来の締切がなければこれを使う
    # （目標は締切 −0〜ウィンドウ分になるので、範囲は従来の「所定 +0〜ウィンドウ分」と同じ）。
    def clock_in_deadline_at(date) = clock_in_default_at(date) + (@config.clock_in_window * 60)

    def time_on(date, hhmm)
      h, m = hhmm.split(":").map(&:to_i)
      Time.new(date.year, date.month, date.day, h, m, 0, Ak4Punch::JST)
    end

    # 取得済みイベントを「休暇」と「業務」に仕分けた LeaveSchedule を作る。
    # events が nil（連動OFF・取得失敗）なら休暇なしの空の集合になる。
    def leave_schedule(events, date)
      LeaveSchedule.build(events: events, keywords: @config.calendar_leave_keywords, date: date)
    end

    def event_label(event)
      return "(不明なイベント)" if event.nil?

      "#{event.display_title} 〜#{event.ends_at.strftime('%H:%M')}"
    end

    # 出勤側のログ用ラベル（アンカーは開始時刻なので開始を出す）。
    def start_event_label(event)
      return "(不明なイベント)" if event.nil?

      "#{event.display_title} #{event.starts_at.strftime('%H:%M')}〜"
    end

    # 当日内の時刻だけを示せばよい場面用の短い書式。
    # base を渡すと日を跨いだ時刻には日付が付く（終日休暇の目標は翌日 00:00 になるため）。
    def hhmm(time, base: nil) = LeaveSchedule.hhmm(time, base: base)
  end
end
