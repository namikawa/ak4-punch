# frozen_string_literal: true

require "date"

module Ak4Punch
  # カレンダー連動の常駐デーモン。
  #
  # 方針（AKASHI は記録時刻＝リクエスト到着時刻のため「打刻したい時刻にPOST」する）:
  #   - 出勤 = ClockInPlanner（カレンダー連動）が決めた打刻締切 − 揺らぎ
  #     （締切 = min(所定出勤時刻+ウィンドウ, 最初の業務イベントの開始)。予定の開始までに打刻を済ませる）
  #   - 退勤 = ClockOutPlanner（カレンダー連動）が決めた基準時刻 + 揺らぎ
  #     （基準 = max(所定退勤時刻, 最後の業務イベントの終了)）
  #   - 揺らぎは日毎・kind毎に固定した秒数（従来のウィンドウ機構を織込）。出勤は締切から手前へ、
  #     退勤は基準から後ろへずらすため、向きが逆になる。
  #   - 15分毎に sukesan を再取得して出勤・退勤の目標を再計算し、変わったら再スケジュール
  #   - tick 毎に due（目標<=現在<=目標+grace）を判定し、範囲内なら打刻。
  #     打刻失敗は grace 窓内で tick 毎にリトライし、窓超過で諦めて通知する。
  #     due 到達時点で既に grace 超過（寝過ごし）なら打刻せず警告＋通知（誤時刻打刻ガード）。
  #   - カレンダーの休暇イベント（タイトルがキーワードに部分一致・時間の閾値なし）は
  #     「その時間帯は勤務しない」の意味で扱う（LeaveSchedule）。業務イベントの判定からは常に
  #     除外し、上で決めた出勤締切・退勤基準がその時間帯に入っていたら休暇の外へ押し出す
  #     （出勤は休暇の終了へ後ろ倒し／退勤は休暇の開始へ前倒し）。押し出しの結果
  #     「出勤締切 >= 退勤基準」になった日は勤務時間ゼロ＝全休として打刻しない
  #     （AKASHI は休暇申請日でも打刻を受理するため、この判定が誤打刻を防ぐ主手段）。
  #   - 異常時（寝過ごしスキップ/リトライ枯渇/トークン再発行失敗/sukesan障害/休暇中のため打刻中止）
  #     のみ Slack に通知する。成功・全休スキップ・目標変更は通知しない。
  #     休暇中の打刻中止は、既に AKASHI に記録があれば通知しない（give_up と同じ扱い）。
  #     ただし定期再取得の失敗は実害がないため、連続失敗が閾値に達するまで通知しない
  #     （DarkWake 中の無通信による一過性の失敗で鳴らさない）。
  #   - 長い sleep はせず tick で進める（Mac スリープ復帰後に正しく追随するため）。
  class Daemon
    KINDS = %i[in out].freeze
    # 揺らぎ乱数のシードを in/out で分けるための salt。
    KIND_SALT = { in: 0x1111, out: 0x2222 }.freeze

    # 1日分の打刻計画（1 kind 分）。
    #   attempted:     窓内で打刻を試行したか（寝過ごしスキップとリトライ枯渇の区別用）
    #   last_error:    最後の打刻失敗のエラー内容（枯渇通知に含める）
    #   final_checked: この目標に対して退勤直前チェックを実施済みか（リトライ中は再実行しない）
    PunchPlan = Struct.new(:kind, :target_at, :done,
                           :attempted, :last_error, :final_checked, keyword_init: true) do
      def done? = done == true
    end

    # 当日「最後に sukesan から取得できたときの休暇情報」。取得に失敗した tick でも
    # 休暇中かどうかを判定できるようにするために保持する（POST 直前の休暇ゲートの判定材料）。
    #   leaves:     そのときの LeaveSchedule
    #   in_target:  そのとき計算した休暇反映後の出勤目標
    #   out_target: そのとき計算した休暇反映後の退勤目標
    #   fetched_at: 取得した時刻（ログ・通知で「いつ時点の情報か」を示す）
    # 各 target が「実際に採用された @punch_plans[kind].target_at」ではないのが肝。
    # 日中に休暇が入って新目標が到達不能になった日は、set_in_plan/set_out_plan が更新を見送って
    # 旧目標（休暇を知らない目標）が残る。まさにその日を止めるための情報なので、
    # 採用されたかどうかに関わらず「休暇を反映して計算した目標」を持っておく必要がある。
    LeaveSnapshot = Struct.new(:leaves, :in_target, :out_target, :fetched_at, keyword_init: true) do
      # kind に対応する「休暇を反映して計算した目標」。
      def target_for(kind) = kind == :in ? in_target : out_target
    end

    # プロセス生存確認（シグナル0は送達せず存在チェックのみ）。
    DEFAULT_ALIVE_CHECK = lambda do |pid|
      Process.kill(0, pid)
      true
    rescue StandardError
      false
    end

    # `punch recheck` 用: 稼働中デーモン（bin/punch daemon）の PID を返す。見つからなければ nil。
    # pgrep で候補を挙げ、シグナル0で生存確認する。pgrep/生存確認は注入可能（テスト用）。
    def self.find_pid(pgrep: -> { `pgrep -f "bin/punch daemon"` },
                      alive: DEFAULT_ALIVE_CHECK,
                      own_pid: Process.pid)
      pgrep.call.split("\n").map(&:to_i)
           .reject { |pid| pid.zero? || pid == own_pid }
           .find { |pid| alive.call(pid) }
    end

    # 依存はすべて注入可能にしてテストで実時間 sleep なしに検証できるようにする。
    #   clock:   -> Time を返す（既定 Ak4Punch.now）
    #   sleeper: ->(sec) 実際の待機（既定 Kernel#sleep）
    def initialize(config:, stamper:, calendar:, calendar_client:, token_store:, client:,
                   wake_scheduler:, logger:,
                   notifier: SlackNotifier.new(webhook_url: nil),
                   clock: -> { Ak4Punch.now }, sleeper: Kernel.method(:sleep))
      @config = config
      @stamper = stamper
      @calendar = calendar
      @calendar_client = calendar_client
      @token_store = token_store
      @client = client
      @wake_scheduler = wake_scheduler
      @logger = logger
      @notifier = notifier
      @clock = clock
      @sleeper = sleeper

      @current_date = nil       # 日付遷移の副作用（前日未打刻の通知・状態リセット）を実施済みの日付
      @plan_date = nil          # 計画の作成に成功した日付（失敗した日は進めず、次の tick で再試行する）
      @punch_plans = {}         # kind => PunchPlan（対象日のみ）
      @leave_day = false        # 全休（休暇で当日の勤務時間がゼロ）。true の間は再取得も打刻もしない
      @leave_snapshot = nil     # 当日最後に取得できた休暇情報（直前取得が失敗した時の判定に使う）
      @last_refresh_at = nil    # 最後に sukesan を再取得した時刻
      @calendar_failure_count = 0 # sukesan 取得の連続失敗回数（成功でリセット。定期再取得の通知判定に使う）
      @notified_keys = []       # 当日通知済みのイベント種別（同日デデュープ用。日付変化でリセット）
      @recheck_requested = false # SIGUSR1（punch recheck）による再計画要求フラグ
      @running = false
    end

    # フォアグラウンド常駐ループ。SIGINT/SIGTERM で綺麗に終了。
    def run
      install_signal_handlers
      @running = true
      @logger.info("カレンダー連動デーモンを開始しました（tick=#{@config.daemon_tick_seconds}秒 / " \
                   "再取得=#{@config.calendar_refresh_interval_minutes}分 / grace=#{@config.daemon_late_grace_minutes}分）")

      while @running
        begin
          tick
        rescue StandardError => e
          @logger.error("tick中にエラー: #{e.class}: #{e.message}")
        end
        @sleeper.call(@config.daemon_tick_seconds) if @running
      end

      @logger.info("デーモンを終了しました")
    end

    # 1 tick 分の処理（テストから直接呼べる）:
    #   再チェック要求 → 日付変化 → 計画作成 / refresh 間隔 → 退勤再計算 / due 判定 → 打刻
    #   → 起床予約の突き合わせ。
    def tick
      now = @clock.call
      # スリープ明け直後の失敗（Wi-Fi 未接続等）を後の tick で拾い直す。無効時は no-op。
      @notifier.retry_pending
      consume_recheck_request
      ensure_day_plan(now)
      refresh_if_due(now)
      fire_due_punches(now)
      # 毎 tick で pmset 起床予約を現状の計画に突き合わせる（add-only・不足分のみ追加）。
      # 同居デーモンの cancelall などで自分の予約が消えても、次の tick で再追加され自己回復する。
      # 予約が揃っていれば pmset -g sched の読み取り1回だけで無言終了する軽い処理。
      reschedule_wakes(now)
    end

    # 再チェック要求（SIGUSR1 / punch recheck）。次の tick で当日を完全再計画する。
    # 用途: カレンダーに誤って休暇イベントを入れて打刻が止まった場合、
    #       イベントを修正してから `punch recheck` で即時に再判定させる。
    def request_recheck!
      @recheck_requested = true
    end

    # 指定日の計画を組み立てて返す（`punch plan` のドライラン表示にも使う）。
    # sukesan の取得は1回だけ行い、休暇・出勤・退勤の計画で共用する。
    def build_day_plan(date:)
      fetched = @config.calendar_enabled ? fetch_events(date) : { events: nil, error: nil }
      leaves = leave_schedule(fetched[:events], date)
      in_plan = plan_clock_in(date: date, events: fetched[:events], leaves: leaves, error: fetched[:error])
      out_plan = plan_clock_out(date: date, events: fetched[:events], leaves: leaves, error: fetched[:error])
      {
        date: date,
        target?: @calendar.target?(date),
        reason: @calendar.reason(date),
        leave_periods: leaves.periods,
        full_leave: full_leave?(in_plan[:deadline], out_plan[:base], leaves),
        in_plan: in_plan[:plan],
        in_target: in_plan[:target],
        in_deadline: in_plan[:deadline],
        in_leave_shifts: in_plan[:leave_shifts],
        in_error: in_plan[:error],
        out_plan: out_plan[:plan],
        out_target: out_plan[:target],
        out_base: out_plan[:base],
        out_leave_shifts: out_plan[:leave_shifts],
        out_error: out_plan[:error],
      }
    end

    private

    def install_signal_handlers
      %w[INT TERM].each do |sig|
        Signal.trap(sig) do
          @running = false
        end
      end
      # 再チェック要求（punch recheck から送られる）。trap 内ではフラグ設定のみ行う。
      Signal.trap("USR1") { request_recheck! }
    end

    # SIGUSR1 のフラグを検知したら当日の計画を破棄して完全再計画する
    # （休暇状態も打刻計画も破棄 → カレンダー再取得 → 再判定）。
    # 打刻済み・断念済みの分まで作り直すが、実際の二重打刻は Stamper の冪等チェックが、
    # 断念時の誤通知は give_up_punch 前の AKASHI 確認（already_stamped?）が防ぐ。
    # 逆に状態を引き継ぐと、grace 超過で断念（done）した退勤をカレンダー修正＋recheck で
    # 復活させられなくなる。
    def consume_recheck_request
      return unless @recheck_requested

      @recheck_requested = false
      @plan_date = nil  # ensure_day_plan が同一日でも再計画する
      @punch_plans = {} # 当日の計画を破棄して完全に作り直す（断念済み・打刻済みの状態も引き継がない）
      # pmset 書き込み失敗で当日の起床予約を無効化していた場合も、再計画に合わせて再試行させる。
      @wake_scheduler.reset!
      @logger.info("再チェック要求を受け付けました。本日の計画を再作成します")
    end

    # 起動時・日付変化時・再チェック要求時に当日計画を作る。
    # 非対象日・全休日は「計画なし（空の計画）」として成功扱いにする（翌日待ち）。
    #
    # 状態を2つに分けて持つ:
    #   @current_date … 日付遷移の副作用（前日未打刻の通知・各種リセット）を実施済みの日付
    #   @plan_date    … 計画の作成に成功した日付
    # 計画の作成中に想定外の例外が出ても @plan_date は進めないため、次の tick で再試行される
    # （以前は計画の完成前に「計画済み」としていたため、組み立て中の例外で当日の打刻が
    #  全て止まり、通知もされないサイレント故障になっていた）。
    def ensure_day_plan(now)
      today = now.to_date
      return if @plan_date == today

      # 日付遷移の副作用は1日1回だけ。再試行の tick で前日未打刻を再通知したり、
      # @notified_keys をリセットして失敗通知を tick 毎に連打したりしないようにする。
      start_new_day(today) if @current_date != today

      build_and_apply_day_plan(now, today)
    rescue StandardError => e
      # @plan_date を進めないので次の tick で再試行される。同日1回だけ通知する。
      @logger.error("本日の打刻計画の作成に失敗しました（#{e.class}: #{e.message}）。次の tick で再試行します。")
      notify_once(:day_plan_failed,
                  "本日の打刻計画の作成に失敗しました（#{e.class}: #{e.message}）。次のtickで再試行します")
    end

    # 日付が変わったときの副作用（前日分の後始末と当日用の状態リセット）。
    def start_new_day(today)
      # 前日の計画を破棄する前に、未打刻のまま日付を跨いだ分がないか確認して通知する。
      # 制約: デーモン再起動でメモリ（@punch_plans）が消えるため、再起動を挟いだ場合は検知できない。
      notify_unpunched_from_previous_day(@current_date) if @current_date

      @current_date = today
      @punch_plans = {}
      @leave_day = false
      @leave_snapshot = nil # 前日の休暇情報を持ち越さない
      @last_refresh_at = nil
      @calendar_failure_count = 0 # 前日の連続失敗を持ち越さない
      @notified_keys = [] # 同日デデュープを日付変化でリセット
      @wake_scheduler.reset!
    end

    # 当日計画を組み立てて状態に反映する。計画はローカルで組み立ててから反映し、
    # 全て成功した最後に @plan_date を進める（部分状態のまま「計画済み」にしない）。
    def build_and_apply_day_plan(now, today)
      reason = @calendar.reason(today)
      if reason
        @logger.info("#{today} は対象日ではないため計画しません（#{reason}）。翌日を待機します。")
        # 計画なし＝当日 targets は空。起床予約は tick 末尾の突き合わせで
        # 翌営業日ブートストラップのみが維持される（既存の予約は消さない）。
        @punch_plans = {}
        @leave_day = false
        @plan_date = today
        return
      end

      # sukesan の取得は1回だけ行い、休暇・出勤・退勤の計画で共用する（二重 fetch 回避）。
      # 取得失敗時は休暇判定不能のため通常営業日として扱う（出勤・退勤とも所定時刻フォールバック）。
      # 取得失敗（CalendarClient::ApiError）はフォールバックで計画が完成するため成功扱いで、
      # 再試行の対象になるのは想定外の例外だけ。
      fetched = @config.calendar_enabled ? fetch_events(today) : { events: nil, error: nil }
      @last_refresh_at = now # ここが当日最初の取得。次の定期再取得はこの時刻から interval 後。
      leaves = leave_schedule(fetched[:events], today)
      in_plan = plan_clock_in(date: today, events: fetched[:events], leaves: leaves, error: fetched[:error])
      out = plan_clock_out(date: today, events: fetched[:events], leaves: leaves, error: fetched[:error])
      remember_leaves(leaves, in_plan, out, now) if fetched[:events]

      notify_sukesan_fallback(fetched[:error]) if fetched[:error]

      # 全休（休暇の押し出しで勤務時間が消えた日）は打刻計画を持たない。
      # 再チェックで休暇イベントが消えていれば下の通常計画に戻る。
      if full_leave?(in_plan[:deadline], out[:base], leaves)
        @leave_day = true
        @punch_plans = {}
        @logger.info("休暇イベント#{leaves.labels} により本日は勤務時間がないため、打刻しません")
        # 計画なし＝tick 末尾の突き合わせで翌営業日ブートストラップのみが維持される。
        @plan_date = today
        return
      end

      @leave_day = false # 再チェックで全休状態を解除できるよう毎回明示的に設定する
      set_in_plan(in_plan, now)
      set_out_plan(out, now)
      @plan_date = today
    end

    # refresh 間隔ごとに sukesan を再取得して出勤・退勤の目標を再計算する。
    # 会議の追加・キャンセル・延長に追随させるため、未完了（done でない）の kind だけを作り直す。
    # 再取得結果が全休（休暇で勤務時間ゼロ）になっていたら残りの打刻を中止する。
    def refresh_if_due(now)
      return if @leave_day # 全休日は打刻計画がなく、再取得も停止する
      return unless @config.calendar_enabled

      # 打刻済み・断念済みの計画は作り直さない。全て完了していれば再取得の必要もない。
      pending = KINDS.select { |kind| @punch_plans[kind] && !@punch_plans[kind].done? }
      return if pending.empty?

      interval = @config.calendar_refresh_interval_minutes * 60
      return if @last_refresh_at && (now - @last_refresh_at) < interval

      fetched = fetch_events(now.to_date)
      @last_refresh_at = now

      # 定期再取得の失敗では打刻目標を所定時刻へ巻き戻さない（直近の有効目標を維持する）。
      # 巻き戻すと、カレンダー由来の遅い目標が所定時刻（＝過去）に化けて grace 超過と判定され、
      # 退勤が恒久スキップ（give_up で done 確定 → 以降 refresh されない）になる事故が起きるため。
      # 打刻直前チェック（postpone_out_by_final_check?）と同じ「取得失敗は現状維持」の安全側に倒す。
      # 次の間隔まで再取得を待つため @last_refresh_at は上で進めてある（30秒毎の連打・ブロッキングを避ける）。
      # Slack 通知は連続失敗が閾値に達するまで抑制する（実害がないため）。DarkWake（同居デーモンの
      # 起床予約に相乗り）で無通信のまま tick が回ると sukesan が Google に到達できず 1 回だけ失敗する、
      # という一過性のケースが構造的に頻発するため。
      # 判定を「最後の成功からの経過時間」にしないのは、Mac がスリープする以上「起床直後に Wi-Fi 未接続で
      # 1 回失敗した」だけでも長時間扱いになって誤検知するため。再取得は refresh_interval でゲートされて
      # いるので 回数 × 間隔 ≒ 経過時間になり、スリープ跨ぎにも強い。
      # ログ（warn）は間引かず毎回出す（事後の障害調査で失敗の全履歴が必要なため）。
      if fetched[:error]
        # 未完了の kind だけを「維持する目標」として並べる（片方しか無い日でも壊れないように）。
        held = pending.map { |kind| "#{label(kind)} #{@punch_plans[kind].target_at.strftime('%H:%M')}" }.join("・")
        @logger.warn("定期再取得に失敗したため、打刻目標を現状（#{held}）のまま維持します（#{fetched[:error]}）")
        if @calendar_failure_count >= @config.calendar_refresh_failure_notify_threshold
          notify_once(:sukesan_fallback,
                      "sukesan からのイベント再取得に#{@calendar_failure_count}回連続で失敗しています。" \
                      "打刻目標は直近の値（#{held}）のまま維持します（#{fetched[:error]}）")
        end
        return
      end

      # 全休判定には出勤締切・退勤基準の両方が要るため、片方だけが未完了でも両方を計算する
      # （どちらも純粋な計算で副作用はない。計画へ反映するのは未完了の kind だけ）。
      date = now.to_date
      leaves = leave_schedule(fetched[:events], date)
      in_plan = plan_clock_in(date: date, events: fetched[:events], leaves: leaves)
      out = plan_clock_out(date: date, events: fetched[:events], leaves: leaves)
      remember_leaves(leaves, in_plan, out, now)
      return if switch_to_full_leave?(leaves, in_plan, out)

      set_in_plan(in_plan, now) if pending.include?(:in)
      set_out_plan(out, now) if pending.include?(:out)
    end

    # 打刻期限（目標時刻の窓の終端 ＝ 目標 + grace）。grace の解釈をここ1箇所に閉じ込める。
    # 参照元は2つある: ① unreachable_target?（give_up の発火判定と、既存計画の更新ガード）
    # ② execute_punch から Stamper / Client に渡し、POST 直前に再判定させる deadline。
    # この2つは必ず同じ端でなければならない。片方だけ動かすと、デーモンは窓が開いていると
    # 判断するのに Stamper が DeadlineExceeded で拒み続け、tick 毎のリトライを重ねた末に
    # 「リトライ上限に達した」という実態と違う内容で通知されることになる。
    def punch_deadline_at(target) = target + (@config.daemon_late_grace_minutes * 60)

    # 打刻期限（punch_deadline_at）を過ぎていて、もう打刻できないか。
    # fire_due_punches の give_up 発火条件そのものであり、set_in_plan / set_out_plan の
    # 「到達不能な新目標では更新を見送る」ガードの正しさは、この2つが同じ規則であることに
    # 依っている（片方だけ変えるとガードが黙って意味を失う）。必ずこの述語を共有すること。
    #
    # 既存計画の更新で採用してはいけない新目標＝この述語が true になる目標。
    # 採用しても fire_due_punches が即座に窓超過と判定して give_up（done 確定）にするだけなので、
    # まだ到達可能な既存目標を潰して打刻機会を失うことになる。出勤・退勤で共通の規則。
    #
    # 判定を「現在時刻以前」ではなく grace 込みにしているのは、目標〜目標+grace の帯なら
    # 新目標を採用した方が良いため。refresh_if_due は fire_due_punches より前に走るので、
    # 同じ tick で速やかに打刻される（見送ると、本来より遅い既存目標まで待つことになる）。
    # late_grace_minutes を refresh_interval_minutes より広く取っておくと、この
    # 「前倒しの取りこぼし」が構造的に起きない。
    def unreachable_target?(target, now)
      now > punch_deadline_at(target)
    end

    # 出勤計画を @punch_plans[:in] に反映する（set_out_plan の鏡像）。
    # 目標が同じなら完了・リトライ状態（done/attempted/last_error）を引き継ぎ、
    # 目標が変わったらリセットする。final_checked は出勤では使わないため常に false。
    #
    # 既存計画の更新で、新目標が到達不能（unreachable_target?）なら更新せず既存の目標を維持する。
    # 例: 9:40 に 9:00 開始の会議が追加されると新目標は 08:55 になるが、grace(10分)を
    # 過ぎているので採用した瞬間に窓超過と判定され、出勤が恒久スキップ（give_up で done 確定）
    # になってしまう。退勤側の「定期再取得の失敗で目標を巻き戻さない」と同じクラスの事故を防ぐ。
    # 逆に grace 内の前倒しは採用する（同じ tick で打刻され「予定の開始までに打刻する」目的に適う）。
    # 起動時の新規作成（既存計画なし）は、目標が過去でもそのまま計画する（従来どおり
    # grace 内なら打刻し、超過していれば give_up の経路に乗せる）。
    def set_in_plan(plan_result, now)
      target = plan_result[:target]
      existing = @punch_plans[:in]
      same_target = !existing.nil? && existing.target_at == target

      if existing && !same_target && unreachable_target?(target, now)
        @logger.warn("出勤目標の更新を見送ります（新目標 #{fmt(target)} は既に打刻期限切れ）。" \
                     "現在の目標 #{fmt(existing.target_at)} を維持します（#{plan_result[:summary]}）")
        return
      end

      if existing && !same_target
        @logger.info("出勤目標を更新: #{fmt(existing.target_at)} → #{fmt(target)}（#{plan_result[:summary]}）")
      elsif existing.nil?
        @logger.info("出勤目標を設定: #{fmt(target)}（#{plan_result[:summary]}）")
      end

      @punch_plans[:in] = PunchPlan.new(
        kind: :in, target_at: target, done: same_target ? existing.done? : false,
        attempted: same_target ? existing.attempted : false,
        last_error: same_target ? existing.last_error : nil,
        final_checked: false,
      )
    end

    # 退勤計画を @punch_plans[:out] に反映する。
    # 目標が同じなら完了・リトライ状態（done/attempted/last_error/final_checked）を引き継ぎ、
    # 目標が変わったらリセットする（新目標では改めて最終チェック→打刻の順で進む）。
    # done を目標一致でゲートするのは、断念（done）した目標の状態が別の目標に伝染して
    # 「打刻もされず起床予約もされない」計画になるのを防ぐため。
    #
    # 出勤と同じく、既存計画の更新で新目標が到達不能（unreachable_target?）なら見送る。
    # 会議が短縮されて目標が前倒しされた場合は、これまでどおり grace 窓内で速やかに打刻する。
    # 見送るのは「採用した瞬間に give_up にしかならない」場合だけ。
    # 例: 18:30-19:00 の会議で退勤目標が 19:01 の日に、18:45 にその会議が削除されると
    # 新目標は所定へ戻って 18:01 になるが、grace を過ぎているので採用した瞬間に窓超過と
    # 判定され、退勤が打刻されないまま「目標 18:01／現在 18:45・44分超過」と通知される。
    # give_up は「Mac がスリープして窓を逃した」ときの誤時刻打刻ガードであり、デーモン自身の
    # 再計画が作った過去目標をこの経路に流すのは筋が違う（通知も寝過ごしたように読めて誤解を招く）。
    # 既存目標（19:01）で打刻すると記録は遅れるが、正解の 18:00 は既に過ぎていて AKASHI は
    # 遡って打刻できない以上どの選択肢でも誤記録になるため、打刻されず手動対応を強いるより
    # 既存目標で打刻する方を採る。
    def set_out_plan(out, now)
      target = out[:target]
      existing = @punch_plans[:out]
      same_target = !existing.nil? && existing.target_at == target

      if existing && !same_target && unreachable_target?(target, now)
        @logger.warn("退勤目標の更新を見送ります（新目標 #{fmt(target)} は既に打刻期限切れ）。" \
                     "現在の目標 #{fmt(existing.target_at)} を維持します（#{out[:summary]}）")
        return
      end

      if existing && !same_target
        @logger.info("退勤目標を更新: #{fmt(existing.target_at)} → #{fmt(target)}（#{out[:summary]}）")
      elsif existing.nil?
        @logger.info("退勤目標を設定: #{fmt(target)}（#{out[:summary]}）")
      end

      @punch_plans[:out] = PunchPlan.new(
        kind: :out, target_at: target, done: same_target ? existing.done? : false,
        attempted: same_target ? existing.attempted : false,
        last_error: same_target ? existing.last_error : nil,
        final_checked: same_target ? existing.final_checked : false,
      )
    end

    # due（目標<=現在<=目標+grace）の打刻を実行。
    # 失敗は grace 窓内で tick 毎にリトライし、窓超過で諦めて通知する。
    # due 到達時点で既に窓超過（未試行＝寝過ごし）なら打刻せず警告＋通知する。
    def fire_due_punches(now)
      return if @leave_day # 全休日は打刻しない

      KINDS.each do |kind|
        plan = @punch_plans[kind]
        next if plan.nil? || plan.done?
        next if now < plan.target_at # まだ

        if unreachable_target?(plan.target_at, now)
          give_up_punch(plan, now)
          next
        end

        # 退勤は打刻直前にカレンダーを最終再取得し、直前の会議延長に追随する。
        # 同一目標に対しては初回 due 時のみ実施し、リトライ中は打刻だけを再試行する
        # （30秒毎に sukesan を叩かない）。目標が変わったら新目標で改めて実施する。
        if kind == :out && !plan.final_checked
          next if postpone_out_by_final_check?(now)

          plan.final_checked = true
        end

        # 打刻の直前に時計を取り直して窓を再判定する。tick 冒頭の now のままだと、
        # tick の途中で Mac がスリープ（プロセス凍結）した場合に、復帰後の実時刻が
        # 窓を超えていても「grace 内」と誤判定して誤った時刻で打刻してしまうため。
        punch_now = @clock.call
        if unreachable_target?(plan.target_at, punch_now)
          give_up_punch(plan, punch_now)
          next
        end

        # 休暇ゲート（POST 直前の単一判定）。出勤・退勤とも、初回もリトライも必ず通す。
        # 休暇による中止の判定はここ1箇所だけに置く。直前チェック（退勤のみ・初回のみ）の中に
        # 置くと、そこを通らない経路（出勤全般・recheck 後の計画作り直し・打刻失敗のリトライ）が
        # 素通しになる。
        next if abort_punch_in_leave?(plan, punch_now)

        ok, error = execute_punch(kind, punch_now, deadline: punch_deadline_at(plan.target_at))
        if ok
          plan.done = true
        else
          # done にせず次の tick で再試行（窓＝grace が自然な上限になる）。
          plan.attempted = true
          plan.last_error = error
        end
      end
      # 起床予約の突き合わせは tick 末尾で毎回行う（done への遷移もそこで反映される）。
    end

    # grace 窓を超過した打刻を断念する。未試行（寝過ごし）とリトライ枯渇で文言を分けて通知する。
    # ただし断念・通知の前に AKASHI を read-only で確認し、既に打刻済みなら通知しない
    # （再起動でメモリ上の done が失われた場合や、窓超過中に手動打刻した場合の誤通知を防ぐ。
    #  打刻経路の冪等チェックは Stamper 内にあるが、give_up は Stamper を通らないためここで確認する）。
    #
    # 通知は「kind + 目標時刻」単位で同日デデュープする。recheck は当日の計画を作り直すため、
    # 期限切れのまま未打刻の kind は何度でも再断念され、同じ内容の通知が繰り返されてしまう。
    # キーを kind だけにしないのは、「断念 → カレンダー修正＋recheck で復活 → 新目標も逃して再断念」
    # という2度目の正当な通知まで潰れ、直ったと誤認させる黙殺になるため（新目標の断念は必ず鳴らす）。
    # ログ（warn）は間引かず毎回出す（事後の障害調査で全履歴が必要なため）。
    def give_up_punch(plan, now)
      if already_stamped?(plan.kind, now.to_date)
        @logger.info("#{label(plan.kind)}は既にAKASHIで打刻済みのため、スキップ通知は出しません" \
                     "（目標 #{fmt(plan.target_at)}）。")
        plan.done = true
        return
      end

      grace_min = @config.daemon_late_grace_minutes
      over_min = ((now - plan.target_at) / 60).floor
      key = [:give_up, plan.kind, plan.target_at]
      if plan.attempted
        @logger.warn("#{label(plan.kind)}打刻はリトライ上限（目標+#{grace_min}分）に達したため諦めます" \
                     "（最後のエラー: #{plan.last_error}）。")
        notify_once(key,
                    "#{label(plan.kind)}打刻に失敗しました（最後のエラー: #{plan.last_error}）。" \
                    "AKASHI で手動打刻してください")
      else
        @logger.warn("#{label(plan.kind)}目標 #{fmt(plan.target_at)} を#{over_min}分超過" \
                     "（現在 #{fmt(now)}、grace #{grace_min}分）。誤時刻打刻を避けるため打刻せずスキップします。")
        notify_once(key,
                    "#{label(plan.kind)}打刻をスキップしました" \
                    "（目標 #{plan.target_at.strftime('%H:%M')}／現在 #{now.strftime('%H:%M')}・#{over_min}分超過）。" \
                    "AKASHI で手動打刻してください")
      end
      plan.done = true
    end

    # 断念・未打刻通知の前の安全確認: この kind の計画した打刻が既に記録済みか。
    # 判定は Stamper#punch_recorded?（当日の打刻履歴を時刻順で見る）に委譲する。
    # 在席状態ベースの冪等(already_done?)ではなく履歴で見ることで、退勤後（[出勤,退勤]）に
    # 再起動しても「出勤が未打刻」と誤判定して通知することがない。
    # 取得に失敗した場合は false（確認不能 → 通知する安全側に倒す）。
    def already_stamped?(kind, date)
      @stamper.punch_recorded?(kind, date)
    rescue StandardError => e
      @logger.warn("打刻済み確認に失敗（#{e.class}: #{e.message}）。確認できないため通知します。")
      false
    end

    # 退勤打刻の直前チェック。sukesan を強制再取得して退勤目標を再計算し、
    # 目標が現在より後ろへ動いていたら計画を更新して打刻を延期する（done にしない。
    # 新目標で改めて due になったら、その時も最終チェックが走る）。
    # 直前に休暇イベントが入って全休になった場合・いま打刻すると休暇中の記録になる場合は中止する。
    # 戻り値: true = 延期/中止（この tick では打刻しない） / false = このまま打刻してよい。
    def postpone_out_by_final_check?(now)
      return false unless @config.calendar_enabled # 連動OFFは最終チェックなし

      fetched = fetch_events(now.to_date)

      # 再取得失敗は安全側（打刻機会を逃さない）に倒し、現在の目標のまま打刻する。
      # 計画も更新しない（フォールバック値で目標を上書きしない。過去バグ 5843f72）。
      # 当日すでに把握している休暇の判定は POST 直前の休暇ゲート（abort_punch_in_leave?）が
      # @leave_snapshot で行うため、ここでは何もしない（この経路も必ずゲートを通る）。
      if fetched[:error]
        @logger.warn("退勤直前チェック: 再取得に失敗したため、現在の目標のまま打刻します")
        return false
      end

      # 取得できたので定期再取得の起点も進める（直後に同じ内容をもう一度取りにいかない）。
      @last_refresh_at = now

      date = now.to_date
      leaves = leave_schedule(fetched[:events], date)
      in_plan = plan_clock_in(date: date, events: fetched[:events], leaves: leaves)
      out = plan_clock_out(date: date, events: fetched[:events], leaves: leaves)
      remember_leaves(leaves, in_plan, out, now)

      # まず全休判定（休暇で勤務時間が消えていたら以降の打刻を中止）。
      return true if switch_to_full_leave?(leaves, in_plan, out)

      # 目標が後ろへ動いていたら延期する。休暇より後ろに予定がある日（中抜け）は、
      # いま休暇の時間帯にいても休暇明けの目標へ延期されるので、この判定を
      # 「現在が休暇の時間帯か」より先に置くこと（順序を逆にすると中抜けの日の退勤を落とす）。
      if out[:target] > now
        @logger.info("退勤直前チェック: 目標が後ろ倒しされたため打刻を延期します")
        # 新目標は now より後（上のガードで確認済み）なので、set_out_plan の到達不能ガードには掛からない。
        set_out_plan(out, now) # 「退勤目標を更新」ログが出る（起床予約は tick 末尾で新目標に追随）
        return true
      end

      # 休暇による中止はここでは判定しない（POST 直前の休暇ゲートに一本化している）。
      false
    end

    # 当日最後に取得できた休暇情報（@leave_snapshot）を保存する。
    # POST 直前の休暇ゲートはこれを唯一の判定材料にする。
    def remember_leaves(leaves, in_plan, out, now)
      @leave_snapshot = LeaveSnapshot.new(leaves: leaves, in_target: in_plan[:target],
                                          out_target: out[:target], fetched_at: now)
    end

    # 出勤・退勤の POST の直前に必ず通す休暇ゲート。休暇による中止判定はこの1箇所だけに置く。
    #
    # 規則: 現在時刻が把握済みの休暇の時間帯に入っているなら打刻しない。ただし現在の計画の
    # 目標が snapshot の同じ kind の目標と一致し、かつ期限内なら打刻してよい。
    #
    # 「一致」が肝。一致するということは、いま打刻しようとしている目標が休暇を反映して
    # 計算されたものだという意味になり、半休の正常系だけが通る（午前休は「休暇の終了−揺らぎ」、
    # 午後休は「休暇の開始+揺らぎ」なので、目標自体が休暇の時間帯の中に入る）。
    # 不一致は「休暇を知らない古い目標を持っている」ことの証拠なので中止する。
    # これで次の3つが kind を問わず同じ規則で塞がる:
    #   ① 日中に休暇が入り、新目標が到達不能で set_in_plan/set_out_plan が更新を見送った日
    #   ② recheck 直後の取得失敗で、所定フォールバックの計画に作り直された日（全休日・半休日とも）
    #   ③ 打刻失敗のリトライ中に定期再取得で休暇を把握した日（退勤の直前チェックを通らない経路）
    # snapshot が無い日（当日一度も取得に成功していない）は判定材料がないので打刻する。
    def abort_punch_in_leave?(plan, now)
      snapshot = @leave_snapshot
      return false if snapshot.nil?
      return false unless snapshot.leaves.covers?(now)

      planned = snapshot.target_for(plan.kind)
      return false if plan.target_at == planned && !unreachable_target?(plan.target_at, now)

      # 中止は確定。ここから先は通知の要否だけを判断する。
      # 既に AKASHI に記録がある場合は通知しない（give_up_punch と同じ慣行）。recheck で
      # 打刻済み状態が破棄されて計画が作り直された日に「手動打刻してください」と誤報しないため。
      if already_stamped?(plan.kind, now.to_date)
        @logger.info("#{label(plan.kind)}は既にAKASHIで打刻済みのため、中止通知は出しません" \
                     "（目標 #{fmt(plan.target_at)}）。")
        plan.done = true
        return true
      end

      # 期限切れの分岐は呼び出し側（fire_due_punches）が先に give_up で処理するため通常は通らないが、
      # ゲートの規則を単独で読めるようにここでも判定する。
      reason =
        if plan.target_at == planned
          "#{label(plan.kind)}目標 #{hhmm(plan.target_at)} は既に打刻期限切れです"
        else
          "現在の#{label(plan.kind)}目標 #{hhmm(plan.target_at)} は、#{hhmm(snapshot.fetched_at)} 時点の" \
            "休暇を反映した目標 #{hhmm(planned, base: now)} と一致しません（休暇を知らない古い目標です）"
        end
      @logger.warn("現在時刻が休暇#{snapshot.leaves.labels}の時間帯のため、" \
                   "#{label(plan.kind)}打刻を中止します。#{reason}")
      # 次の tick で毎回やり直さないよう done にする（窓超過の断念通知も出さない）。復帰は punch recheck。
      plan.done = true
      # 通知キーに kind と目標時刻を含める（give_up_punch と同じ慣行）。recheck で計画を復活させた
      # 後の別目標での中止は、同じ日でも改めて通知する必要があるため。
      notify_once([:leave_abort, plan.kind, plan.target_at],
                  "#{label(plan.kind)}打刻を中止しました（現在 #{hhmm(now)} は" \
                  "休暇#{snapshot.leaves.labels}の時間帯です。#{reason}）。" \
                  "必要であれば AKASHI で手動打刻してください")
      true
    end

    # 再計算の結果が全休（休暇の押し出しで勤務時間ゼロ）なら、未実行の打刻計画を破棄して
    # 以降の打刻を中止する。戻り値: true = 全休に切り替えた。
    def switch_to_full_leave?(leaves, in_plan, out)
      return false unless full_leave?(in_plan[:deadline], out[:base], leaves)

      @leave_day = true
      @punch_plans = {}
      @logger.warn("休暇イベント#{leaves.labels} により本日の勤務時間がなくなったため、以降の打刻を中止します。" \
                   "打刻済みの分は手動で削除してください")
      # 当日 targets が空になる。既存の予約は消さず、tick 末尾の突き合わせで
      # 翌営業日ブートストラップのみが維持される（残った当日予約は発火しても無害）。
      true
    end

    # sukesan から指定日のイベントを取得する。失敗時は events: nil + error(メッセージ)。
    # 連続失敗回数（@calendar_failure_count）はここで一元管理する
    # （呼び出し元が計画時・定期再取得・打刻直前チェックと複数あるため）。
    def fetch_events(date)
      events = @calendar_client.events(date: date)
      if @calendar_failure_count.positive?
        @logger.info("sukesan のイベント取得が復旧しました（連続失敗 #{@calendar_failure_count} 回）")
        @calendar_failure_count = 0
      end
      { events: events, error: nil }
    rescue CalendarClient::ApiError => e
      @calendar_failure_count += 1
      { events: nil, error: e.message }
    end

    # 取得済みイベントを「休暇」と「業務」に仕分けた LeaveSchedule を作る。
    # events が nil（連動OFF・取得失敗）なら休暇なしの空の集合になる。
    def leave_schedule(events, date)
      LeaveSchedule.build(events: events, keywords: @config.calendar_leave_keywords, date: date)
    end

    # 休暇の押し出し後に「出勤締切 >= 退勤基準」＝勤務時間ゼロになったか（＝全休）。
    # 終日休暇（00:00〜翌00:00）もこの判定で全休になるため、全休は特別ルールではなく帰結。
    # 判定は揺らぎを足す前の締切・基準で行う（揺らぎの向きで勤務時間の有無が変わらないように）。
    # 休暇イベントが1件もない日は判定しない（所定退勤 <= 所定出勤 という設定ミスのときに
    # 「全休」として黙って打刻を止めないため）。
    def full_leave?(deadline, base, leaves) = leaves.any? && deadline >= base

    # 実際の打刻。トークン更新（CLI#run_punch 相当）→ Stamper#punch（window=0 で即時）。
    # 揺らぎは目標時刻に織込済みのため window は 0 で呼ぶ。冪等・対象日判定は Stamper に委ねる。
    # deadline（目標+grace）も渡し、トークン再発行や冪等チェックの GET の途中でスリープした
    # 場合の誤時刻打刻を POST の直前で止める。中止（Ak4Punch::DeadlineExceeded）は他の打刻失敗と
    # 同じ扱いで返し、次の tick で窓超過と判定されて give_up_punch が通知する
    # （専用の通知経路は作らない）。
    # 戻り値: [成功(true/false), エラー内容(String or nil)]。
    # 成功には「打刻済みで冪等スキップ」も含む。失敗（例外）は呼び出し側がリトライする。
    def execute_punch(kind, now, deadline:)
      if @token_store.needs_refresh?(now: now)
        @logger.info("トークンの有効期限が近いため再発行します")
        begin
          @token_store.refresh!(@client)
        rescue StandardError => e
          message = "トークン再発行失敗: #{e.class}: #{e.message}"
          @logger.error("#{message}。次の tick で再試行します。")
          # リトライ毎に鳴らさないよう同日1回だけ通知する。
          notify_once(:token_refresh_failed,
                      "トークンの再発行に失敗しました（#{e.message}）。マイページでの再発行が必要かもしれません")
          return [false, message]
        end
      end

      @stamper.punch(kind: kind, date: now.to_date, window_minutes: 0, deadline: deadline)
      [true, nil]
    rescue StandardError => e
      message = "#{e.class}: #{e.message}"
      @logger.error("#{label(kind)}の打刻に失敗: #{message}。次の tick で再試行します。")
      [false, message]
    end

    # 同日1回だけ通知する（デデュープ。@notified_keys は日付変化でリセット）。
    # key は Symbol、または事象を特定する組（例: [:give_up, kind, 目標時刻]）。
    def notify_once(key, message)
      return if @notified_keys.include?(key)

      @notified_keys << key
      @notifier.notify(message)
    end

    # 日付切替時、前日の @punch_plans に未完了（done でない）計画が残っていれば警告＋通知する。
    # 未打刻のまま一度も起きずに0時を跨いだケース（誤時刻打刻ガードで grace 窓を逃した等）を拾う。
    # 休暇日は @punch_plans が空なので誤報しない。通知は SlackNotifier の再送（pending）機構に乗る
    # （起床直後で Wi-Fi 未接続でも、後の tick で届く）。
    def notify_unpunched_from_previous_day(prev_date)
      @punch_plans.each_value do |plan|
        # done でなくても AKASHI に打刻があれば（再起動後の突き合わせ・手動打刻など）通知しない。
        next if plan.done? || already_stamped?(plan.kind, prev_date)

        @logger.warn("昨日（#{prev_date}）の#{label(plan.kind)}が未打刻のまま日付が変わりました。")
        @notifier.notify("昨日（#{prev_date}）の#{label(plan.kind)}は打刻されませんでした" \
                         "（未打刻のまま日付が変わりました）。AKASHI で手動申請してください")
      end
    end

    # 起動時・日付変化時の取得失敗の通知。こちらは1回目から通知する
    # （所定時刻フォールバック＋休暇判定不能という実害があるため）。
    # 通知キーは定期再取得の抑制付き通知と共有するので、合わせて同日1通に収まる。
    def notify_sukesan_fallback(error)
      notify_once(:sukesan_fallback,
                  "sukesan からのイベント取得に失敗し、出勤・退勤とも所定時刻にフォールバックしています（#{error}）")
    end

    # 現状の計画（未完了の打刻目標＋翌営業日ブートストラップ）に pmset 起床予約を
    # 突き合わせ、不足分だけを追加する。tick 末尾から毎回呼ばれる。WakeScheduler は
    # add-only（不足分のみ追加・何も消さない）なので、揃っていれば読み取り1回で無言終了し、
    # 消されていれば再追加する。manage_wake=false のときは pmset に一切触らない。
    def reschedule_wakes(now)
      return unless @config.daemon_manage_wake

      targets = @punch_plans.values.reject(&:done?).map(&:target_at).select { |t| t > now }
      # ブートストラップ起床: 当日の打刻が全て完了する（targets が空になる）と、
      # スリープしたままでは翌営業日の計画を作れず朝に起きられない。
      # そのため「次の営業日の朝の起床時刻」（揺らぎなし）を常に予約しておく。
      # lead 分の前倒しは WakeScheduler 側で行われ、起床後最初の tick で
      # 当日計画が作られて正確な打刻目標の wake が再予約される。
      bootstrap = next_workday_morning_wake(now)
      targets << bootstrap if bootstrap
      @wake_scheduler.reschedule(targets)
    end

    # 翌日以降で最初の営業日の朝の起床時刻(Time)を返す。安全のため最大366日で打ち切り。
    def next_workday_morning_wake(now)
      date = now.to_date + 1
      366.times do
        return morning_wake_time(date) if @calendar.target?(date)

        date += 1
      end
      nil
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
    # 出勤目標は plan_clock_in でこの時刻にクランプするため、これを下回らない。
    def morning_wake_time(date)
      default = clock_in_default_at(date)
      hhmm = @config.daemon_morning_wake_at
      return default if hhmm.nil?

      [time_on(date, hhmm), default].min
    end

    # 出勤の目標時刻を計算する。events は取得済みイベント配列
    # （nil は未取得＝連動OFF、または取得失敗。失敗時は error にメッセージ）。
    # 取得自体は呼び出し側が fetch_events で行い、休暇・退勤計画と共用する。
    # leaves は当日の休暇イベント（LeaveSchedule）。業務イベントの判定から休暇を外し、
    # 決めた締切が休暇の時間帯に入っていたら休暇の外（終了時刻）へ後ろ倒しする。
    #
    # 出勤は「締切ベース」で決める: 打刻締切 = min(所定出勤時刻+ウィンドウ, 最初の業務イベント開始)、
    # 目標 = 締切 − 揺らぎ（朝の起床時刻でクランプ）。
    # 予定なしの日の範囲（所定〜所定+ウィンドウ）は従来と変わらない。
    # 返り値: { target:, plan:(Plan or nil), deadline:, summary:(String), error:(String or nil),
    #          leave_shifts:(Shift 配列) }
    def plan_clock_in(date:, events:, leaves:, error: nil)
      default = clock_in_deadline_at(date)
      earliest = morning_wake_time(date) # アンカーの下限 兼 目標のクランプ下限
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

      { target: in_target_at(deadline, date, earliest), plan: plan, deadline: deadline,
        summary: summary, error: error, leave_shifts: shifts }
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
    # 取得自体は呼び出し側が fetch_events で行い、休暇・出勤計画と共用する。
    # leaves は当日の休暇イベント（LeaveSchedule）。業務イベントの判定から休暇を外し、
    # 決めた基準が休暇の時間帯に入っていたら休暇の外（開始時刻）へ前倒しする。
    # 返り値: { target:, plan:(Plan or nil), base:, summary:(String), error:(String or nil),
    #          leave_shifts:(Shift 配列) }
    def plan_clock_out(date:, events:, leaves:, error: nil)
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

      { target: apply_jitter(base, date, :out), plan: plan, base: base,
        summary: summary, error: error, leave_shifts: shifts }
    end

    # 基準時刻に「日毎・kind毎に固定した揺らぎ秒」を足す（退勤: 基準は下限なので後ろへずらす）。
    def apply_jitter(base_time, date, kind) = base_time + jitter_seconds(date, kind)

    # 締切から「日毎・kind毎に固定した揺らぎ秒」を引く（出勤: 基準は締切なので手前へずらす）。
    def apply_jitter_before(deadline, date, kind) = deadline - jitter_seconds(date, kind)

    # 日毎・kind毎に固定した揺らぎ秒。定期再取得のたびに目標がブレないよう、
    # 日付とkindから決定論的に決める（このシードの導出は変えないこと）。
    def jitter_seconds(date, kind)
      window = kind == :in ? @config.clock_in_window : @config.clock_out_window
      return 0 unless window.positive?

      seed = date.to_time.to_i ^ KIND_SALT.fetch(kind)
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

    def event_label(event)
      return "(不明なイベント)" if event.nil?

      "#{event.display_title} 〜#{event.ends_at.strftime('%H:%M')}"
    end

    # 出勤側のログ用ラベル（アンカーは開始時刻なので開始を出す）。
    def start_event_label(event)
      return "(不明なイベント)" if event.nil?

      "#{event.display_title} #{event.starts_at.strftime('%H:%M')}〜"
    end

    def label(kind) = KIND_LABELS.fetch(kind)
    def fmt(time) = time.strftime("%Y-%m-%d %H:%M:%S")
    # 当日内の時刻だけを示せばよい場面（休暇ゲートのログ・通知）用の短い書式。
    # base を渡すと日を跨いだ時刻には日付が付く（終日休暇の目標は翌日 00:00 になるため）。
    def hhmm(time, base: nil) = LeaveSchedule.hhmm(time, base: base)
  end
end
