# frozen_string_literal: true

require "date"

module Ak4Punch
  # カレンダー連動の常駐デーモン。
  #
  # 方針（AKASHI は記録時刻＝リクエスト到着時刻のため「打刻したい時刻にPOST」する）:
  #   - 出勤 = 所定時刻 + 揺らぎ（従来のウィンドウ機構を日毎固定の秒数として織込）
  #   - 退勤 = ClockOutPlanner（カレンダー連動）+ 揺らぎ
  #   - 15分毎に sukesan を再取得して退勤目標を再計算し、変わったら再スケジュール
  #   - tick 毎に due（目標<=現在<=目標+grace）を判定し、範囲内なら打刻。
  #     打刻失敗は grace 窓内で tick 毎にリトライし、窓超過で諦めて通知する。
  #     due 到達時点で既に grace 超過（寝過ごし）なら打刻せず警告＋通知（誤時刻打刻ガード）。
  #   - カレンダーに休暇イベント（キーワード部分一致＋終日 or 一定時間以上）を
  #     検知したら、その日は打刻しない（AKASHI は休暇申請日でも打刻を受理するため）。
  #   - 異常時（寝過ごしスキップ/リトライ枯渇/トークン再発行失敗/sukesan障害）のみ
  #     Slack に通知する。成功・休暇検知・目標変更は通知しない。
  #   - 長い sleep はせず tick で進める（Mac スリープ復帰後に正しく追随するため）。
  class Daemon
    KINDS = %i[in out].freeze
    # 揺らぎ乱数のシードを in/out で分けるための salt。
    KIND_SALT = { in: 0x1111, out: 0x2222 }.freeze

    # 1日分の打刻計画（1 kind 分）。
    #   attempted:     窓内で打刻を試行したか（寝過ごしスキップとリトライ枯渇の区別用）
    #   last_error:    最後の打刻失敗のエラー内容（枯渇通知に含める）
    #   final_checked: この目標に対して退勤直前チェックを実施済みか（リトライ中は再実行しない）
    PunchPlan = Struct.new(:kind, :target_at, :done, :plan_detail,
                           :attempted, :last_error, :final_checked, keyword_init: true) do
      def done? = done == true
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

      @plan_date = nil          # 現在計画中の日付
      @punch_plans = {}         # kind => PunchPlan（対象日のみ）
      @leave_event = nil        # 検知した休暇イベント（非nilの間、当日は「休暇日」として打刻しない）
      @last_refresh_at = nil    # 最後に sukesan を再取得した時刻
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
    #   再チェック要求 → 日付変化 → 計画作成 / refresh 間隔 → 退勤再計算 / due 判定 → 打刻。
    def tick
      now = @clock.call
      # スリープ明け直後の失敗（Wi-Fi 未接続等）を後の tick で拾い直す。無効時は no-op。
      @notifier.retry_pending
      consume_recheck_request
      ensure_day_plan(now)
      refresh_if_due(now)
      fire_due_punches(now)
    end

    # 再チェック要求（SIGUSR1 / punch recheck）。次の tick で当日を完全再計画する。
    # 用途: カレンダーに誤って休暇イベントを入れて打刻が止まった場合、
    #       イベントを修正してから `punch recheck` で即時に再判定させる。
    def request_recheck!
      @recheck_requested = true
    end

    # 指定日の計画を組み立てて返す（`punch plan` のドライラン表示にも使う）。
    # sukesan の取得は1回だけ行い、休暇判定と退勤計画で共用する。
    def build_day_plan(date:)
      fetched = @config.calendar_enabled ? fetch_events(date) : { events: nil, error: nil }
      leave = fetched[:events] ? detect_leave(fetched[:events]) : nil
      out_plan = plan_clock_out(date: date, events: fetched[:events], error: fetched[:error])
      {
        date: date,
        target?: @calendar.target?(date),
        reason: @calendar.reason(date),
        leave_event: leave,
        in_target: in_target_at(date),
        out_plan: out_plan[:plan],
        out_target: out_plan[:target],
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
      Signal.trap("USR1") { @recheck_requested = true }
    end

    # SIGUSR1 のフラグを検知したら当日の計画を破棄して完全再計画する
    # （休暇状態も破棄 → カレンダー再取得 → 再判定。冪等チェックは Stamper 側にあるため
    #  打刻済みの分が二重打刻されることはない）。
    def consume_recheck_request
      return unless @recheck_requested

      @recheck_requested = false
      @plan_date = nil # ensure_day_plan が同一日でも再計画する
      @logger.info("再チェック要求を受け付けました。本日の計画を再作成します")
    end

    # 起動時・日付変化時に当日計画を作る。非対象日は計画なし（翌日待ち）。
    # カレンダーに休暇イベントを検知した日も計画なし（休暇日として保持）。
    def ensure_day_plan(now)
      today = now.to_date
      return if @plan_date == today

      # 前日の計画を破棄する前に、未打刻のまま日付を跨いだ分がないか確認して通知する。
      # 制約: デーモン再起動でメモリ（@punch_plans）が消えるため、再起動を挟いだ場合は検知できない。
      notify_unpunched_from_previous_day if @plan_date

      @plan_date = today
      @punch_plans = {}
      @leave_event = nil
      @last_refresh_at = nil
      @notified_keys = [] # 同日デデュープを日付変化でリセット
      @wake_scheduler.reset!

      reason = @calendar.reason(today)
      if reason
        @logger.info("#{today} は対象日ではないため計画しません（#{reason}）。翌日を待機します。")
        # 計画なし＝targets は空。前日の予約が残っていれば消す（manage_wake 有効時のみ pmset に触る）。
        reschedule_wakes(now)
        return
      end

      # sukesan の取得は1回だけ行い、休暇判定と退勤計画で共用する（二重 fetch 回避）。
      # 取得失敗時は休暇判定不能のため通常営業日として扱う（退勤は所定時刻フォールバック）。
      fetched = @config.calendar_enabled ? fetch_events(today) : { events: nil, error: nil }
      notify_sukesan_fallback(fetched[:error]) if fetched[:error]
      if fetched[:events] && (leave = detect_leave(fetched[:events]))
        @leave_event = leave
        @logger.info("休暇イベント『#{leave.title}』を検知したため、本日は打刻しません")
        reschedule_wakes(now) # 計画なし＝翌営業日ブートストラップのみ予約される
        return
      end

      in_target = in_target_at(today)
      @punch_plans[:in] = PunchPlan.new(kind: :in, target_at: in_target, done: false,
                                        plan_detail: "所定#{@config.clock_in_time}+揺らぎ")
      @logger.info("出勤目標を設定: #{fmt(in_target)}")

      out = plan_clock_out(date: today, events: fetched[:events], error: fetched[:error])
      set_out_plan(out, now)
      reschedule_wakes(now)
    end

    # refresh 間隔ごとに sukesan を再取得して退勤目標を再計算する。
    # 再取得結果にまず休暇判定を適用し、検知したら残りの打刻を中止する。
    def refresh_if_due(now)
      return if @leave_event # 休暇日は打刻計画がなく、再取得も停止する
      return unless @config.calendar_enabled
      return unless @punch_plans.key?(:out)
      return if @punch_plans[:out].done? # 退勤済みなら再取得不要

      interval = @config.calendar_refresh_interval_minutes * 60
      return if @last_refresh_at && (now - @last_refresh_at) < interval

      fetched = fetch_events(now.to_date)
      notify_sukesan_fallback(fetched[:error]) if fetched[:error]
      return if switch_to_leave_day?(fetched[:events], now)

      out = plan_clock_out(date: now.to_date, events: fetched[:events], error: fetched[:error])
      before = @punch_plans[:out].target_at
      set_out_plan(out, now)
      after = @punch_plans[:out].target_at

      reschedule_wakes(now) if after != before
    end

    # 退勤計画を @punch_plans[:out] に反映する。
    # 目標が同じならリトライ状態（attempted/last_error/final_checked）を引き継ぎ、
    # 目標が変わったらリセットする（新目標では改めて最終チェック→打刻の順で進む）。
    def set_out_plan(out, now)
      @last_refresh_at = now
      target = out[:target]
      existing = @punch_plans[:out]
      same_target = !existing.nil? && existing.target_at == target

      if existing && !same_target
        @logger.info("退勤目標を更新: #{fmt(existing.target_at)} → #{fmt(target)}（#{out[:summary]}）")
      elsif existing.nil?
        @logger.info("退勤目標を設定: #{fmt(target)}（#{out[:summary]}）")
      end

      @punch_plans[:out] = PunchPlan.new(
        kind: :out, target_at: target, done: existing&.done? || false, plan_detail: out[:summary],
        attempted: same_target ? existing.attempted : false,
        last_error: same_target ? existing.last_error : nil,
        final_checked: same_target ? existing.final_checked : false,
      )
    end

    # due（目標<=現在<=目標+grace）の打刻を実行。
    # 失敗は grace 窓内で tick 毎にリトライし、窓超過で諦めて通知する。
    # due 到達時点で既に窓超過（未試行＝寝過ごし）なら打刻せず警告＋通知する。
    def fire_due_punches(now)
      return if @leave_event # 休暇日は打刻しない

      grace = @config.daemon_late_grace_minutes * 60
      transitioned = false
      KINDS.each do |kind|
        plan = @punch_plans[kind]
        next if plan.nil? || plan.done?
        next if now < plan.target_at # まだ

        if now > plan.target_at + grace
          give_up_punch(plan, now)
          transitioned = true
          next
        end

        # 退勤は打刻直前にカレンダーを最終再取得し、直前の会議延長に追随する。
        # 同一目標に対しては初回 due 時のみ実施し、リトライ中は打刻だけを再試行する
        # （30秒毎に sukesan を叩かない）。目標が変わったら新目標で改めて実施する。
        if kind == :out && !plan.final_checked
          next if postpone_out_by_final_check?(now)

          plan.final_checked = true
        end

        ok, error = execute_punch(kind, now)
        if ok
          plan.done = true
          transitioned = true
        else
          # done にせず次の tick で再試行（窓＝grace が自然な上限になる）。
          plan.attempted = true
          plan.last_error = error
        end
      end

      # 打刻完了/断念で done へ遷移したら、残り目標＋ブートストラップで予約し直す
      # （当日分の縮小を反映しつつ、翌営業日朝の起床予約を維持する）。
      reschedule_wakes(now) if transitioned
    end

    # grace 窓を超過した打刻を断念する。未試行（寝過ごし）とリトライ枯渇で文言を分けて通知する。
    def give_up_punch(plan, now)
      grace_min = @config.daemon_late_grace_minutes
      if plan.attempted
        @logger.warn("#{label(plan.kind)}打刻はリトライ上限（目標+#{grace_min}分）に達したため諦めます" \
                     "（最後のエラー: #{plan.last_error}）。")
        @notifier.notify("#{label(plan.kind)}打刻に失敗しました（最後のエラー: #{plan.last_error}）。" \
                         "AKASHI で手動打刻してください")
      else
        @logger.warn("#{label(plan.kind)}目標 #{fmt(plan.target_at)} を#{grace_min}分超過（現在 #{fmt(now)}）。" \
                     "誤時刻打刻を避けるため打刻せずスキップします。")
        @notifier.notify("#{label(plan.kind)}打刻をスキップしました" \
                         "（目標 #{plan.target_at.strftime('%H:%M')} を#{grace_min}分超過）。AKASHI で手動打刻してください")
      end
      plan.done = true
    end

    # 退勤打刻の直前チェック。sukesan を強制再取得して退勤目標を再計算し、
    # 目標が現在より後ろへ動いていたら計画を更新して打刻を延期する（done にしない。
    # 新目標で改めて due になったら、その時も最終チェックが走る）。
    # 直前に休暇イベントが入っていた場合は打刻を中止して休暇日に切り替える。
    # 戻り値: true = 延期/中止（この tick では打刻しない） / false = このまま打刻してよい。
    def postpone_out_by_final_check?(now)
      return false unless @config.calendar_enabled # 連動OFFは最終チェックなし

      fetched = fetch_events(now.to_date)

      # 再取得失敗は安全側（打刻機会を逃さない）に倒し、現在の目標のまま打刻する。
      # 計画も更新しない（フォールバック値で目標を上書きしない）。
      if fetched[:error]
        @logger.warn("退勤直前チェック: 再取得に失敗したため、現在の目標のまま打刻します")
        return false
      end

      # まず休暇判定（検知したら以降の打刻を中止）。
      return true if switch_to_leave_day?(fetched[:events], now)

      out = plan_clock_out(date: now.to_date, events: fetched[:events])

      # 目標が不変・前倒しなら、いま打刻するのが正しい（grace の再判定はしない）。
      return false if out[:target] <= now

      @logger.info("退勤直前チェック: 目標が後ろ倒しされたため打刻を延期します")
      set_out_plan(out, now) # 「退勤目標を更新」ログが出る
      reschedule_wakes(now)  # 起床予約も新目標で取り直す
      true
    end

    # 取得済みイベントに休暇判定を適用し、検知したら未実行の打刻計画を破棄して
    # 休暇日に切り替える。戻り値: true = 休暇日に切り替えた。
    def switch_to_leave_day?(events, now)
      return false if events.nil?

      leave = detect_leave(events)
      return false unless leave

      @leave_event = leave
      @punch_plans = {}
      @logger.warn("休暇イベント『#{leave.title}』を検知したため、以降の打刻を中止します。" \
                   "打刻済みの分は手動で削除してください")
      reschedule_wakes(now) # 当日分の予約を整理（翌営業日ブートストラップのみ残る）
      true
    end

    # sukesan から指定日のイベントを取得する。失敗時は events: nil + error(メッセージ)。
    def fetch_events(date)
      { events: @calendar_client.events(date: date), error: nil }
    rescue CalendarClient::ApiError => e
      { events: nil, error: e.message }
    end

    def detect_leave(events)
      LeaveDetector.new(
        keywords: @config.calendar_leave_keywords,
        min_duration_hours: @config.calendar_leave_min_duration_hours,
      ).detect(events)
    end

    # 実際の打刻。トークン更新（CLI#run_punch 相当）→ Stamper#punch（window=0 で即時）。
    # 揺らぎは目標時刻に織込済みのため window は 0 で呼ぶ。冪等・対象日判定は Stamper に委ねる。
    # 戻り値: [成功(true/false), エラー内容(String or nil)]。
    # 成功には「打刻済みで冪等スキップ」も含む。失敗（例外）は呼び出し側がリトライする。
    def execute_punch(kind, now)
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

      @stamper.punch(kind: kind, date: now.to_date, window_minutes: 0)
      [true, nil]
    rescue StandardError => e
      message = "#{e.class}: #{e.message}"
      @logger.error("#{label(kind)}の打刻に失敗: #{message}。次の tick で再試行します。")
      [false, message]
    end

    # 同日1回だけ通知する（デデュープ。@notified_keys は日付変化でリセット）。
    def notify_once(key, message)
      return if @notified_keys.include?(key)

      @notified_keys << key
      @notifier.notify(message)
    end

    # 日付切替時、前日の @punch_plans に未完了（done でない）計画が残っていれば警告＋通知する。
    # 未打刻のまま一度も起きずに0時を跨いだケース（誤時刻打刻ガードで grace 窓を逃した等）を拾う。
    # 休暇日は @punch_plans が空なので誤報しない。通知は SlackNotifier の再送（pending）機構に乗る
    # （起床直後で Wi-Fi 未接続でも、後の tick で届く）。
    def notify_unpunched_from_previous_day
      prev_date = @plan_date
      @punch_plans.each_value do |plan|
        next if plan.done?

        @logger.warn("昨日（#{prev_date}）の#{label(plan.kind)}が未打刻のまま日付が変わりました。")
        @notifier.notify("昨日（#{prev_date}）の#{label(plan.kind)}は打刻されませんでした" \
                         "（未打刻のまま日付が変わりました）。AKASHI で手動申請してください")
      end
    end

    # sukesan 障害による所定時刻フォールバックの通知（30分毎の再取得失敗で連打しない）。
    def notify_sukesan_fallback(error)
      notify_once(:sukesan_fallback,
                  "sukesan からのイベント取得に失敗し、退勤は所定時刻にフォールバックしています（#{error}）")
    end

    # 残っている（未実行の）当日打刻目標＋ブートストラップ目標について wake を予約し直す。
    def reschedule_wakes(now)
      return unless @config.daemon_manage_wake

      targets = @punch_plans.values.reject(&:done?).map(&:target_at).select { |t| t > now }
      # ブートストラップ起床: 当日の打刻が全て完了する（targets が空になる）と、
      # スリープしたままでは翌営業日の計画を作れず朝に起きられない。
      # そのため「次の営業日の所定出勤時刻」（揺らぎなし）を常に予約しておく。
      # lead 分の前倒しは WakeScheduler 側で行われ、起床後最初の tick で
      # 当日計画が作られて正確な打刻目標の wake が再予約される。
      bootstrap = next_workday_clock_in(now)
      targets << bootstrap if bootstrap
      @wake_scheduler.reschedule(targets)
    end

    # 翌日以降で最初の営業日の所定出勤時刻(Time)を返す。安全のため最大366日で打ち切り。
    def next_workday_clock_in(now)
      date = now.to_date + 1
      366.times do
        return clock_in_default_at(date) if @calendar.target?(date)

        date += 1
      end
      nil
    end

    # 退勤の目標時刻を計算する。events は取得済みイベント配列
    # （nil は未取得＝連動OFF、または取得失敗。失敗時は error にメッセージ）。
    # 取得自体は呼び出し側が fetch_events で行い、休暇判定と共用する。
    # 返り値: { target:, plan:(Plan or nil), summary:(String), error:(String or nil) }
    def plan_clock_out(date:, events:, error: nil)
      default = clock_out_default_at(date)

      # 連動OFFなら所定時刻（+揺らぎ）を使う（sukesan にはアクセスしない前提）。
      unless @config.calendar_enabled
        return { target: apply_jitter(default, date, :out), plan: nil,
                 summary: "カレンダー連動OFF（所定時刻）", error: nil }
      end

      if events.nil?
        @logger.warn("sukesan からのイベント取得に失敗しました（#{error}）。所定退勤時刻へフォールバックします。")
        summary = "sukesan 障害のため所定時刻へフォールバック"
        return { target: apply_jitter(default, date, :out), plan: nil, summary: summary, error: error }
      end

      plan = ClockOutPlanner.new(exclude_keywords: @config.calendar_exclude_keywords)
                            .plan(events: events, date: date, default_clock_out: default)
      summary =
        if plan.source == :calendar
          "採用: #{event_label(plan.adopted_event)}"
        else
          "所定時刻（#{plan.fallback_reason}）"
        end

      { target: apply_jitter(plan.target_at, date, :out), plan: plan, summary: summary, error: nil }
    end

    # 出勤の目標時刻 = 所定時刻 + 日毎固定の揺らぎ。
    def in_target_at(date)
      apply_jitter(clock_in_default_at(date), date, :in)
    end

    # 基準時刻に「日毎・kind毎に固定した揺らぎ秒」を足す。
    # 15分毎の再計画で目標がブレないよう、日付とkindから決定論的に決める。
    def apply_jitter(base_time, date, kind)
      window = kind == :in ? @config.clock_in_window : @config.clock_out_window
      return base_time unless window.positive?

      seed = date.to_time.to_i ^ KIND_SALT.fetch(kind)
      delay = Random.new(seed).rand(0..(window * 60))
      base_time + delay
    end

    def clock_in_default_at(date) = time_on(date, @config.clock_in_time)
    def clock_out_default_at(date) = time_on(date, @config.clock_out_time)

    def time_on(date, hhmm)
      h, m = hhmm.split(":").map(&:to_i)
      Time.new(date.year, date.month, date.day, h, m, 0, Ak4Punch::JST)
    end

    def event_label(event)
      return "(不明なイベント)" if event.nil?

      title = event.title.nil? || event.title.empty? ? "(タイトルなし)" : event.title
      "#{title} 〜#{event.ends_at.strftime('%H:%M')}"
    end

    def label(kind) = kind == :in ? "出勤" : "退勤"
    def fmt(time) = time.strftime("%Y-%m-%d %H:%M:%S")
  end
end
