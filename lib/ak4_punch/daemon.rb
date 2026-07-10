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
  #     grace 超過は打刻せず警告（スリープ寝過ごし時の誤時刻打刻ガード）。
  #   - 長い sleep はせず tick で進める（Mac スリープ復帰後に正しく追随するため）。
  class Daemon
    KINDS = %i[in out].freeze
    # 揺らぎ乱数のシードを in/out で分けるための salt。
    KIND_SALT = { in: 0x1111, out: 0x2222 }.freeze

    # 1日分の打刻計画（1 kind 分）。
    PunchPlan = Struct.new(:kind, :target_at, :done, :plan_detail, keyword_init: true) do
      def done? = done == true
    end

    # 依存はすべて注入可能にしてテストで実時間 sleep なしに検証できるようにする。
    #   clock:   -> Time を返す（既定 Ak4Punch.now）
    #   sleeper: ->(sec) 実際の待機（既定 Kernel#sleep）
    def initialize(config:, stamper:, calendar:, calendar_client:, token_store:, client:,
                   wake_scheduler:, logger:,
                   clock: -> { Ak4Punch.now }, sleeper: Kernel.method(:sleep))
      @config = config
      @stamper = stamper
      @calendar = calendar
      @calendar_client = calendar_client
      @token_store = token_store
      @client = client
      @wake_scheduler = wake_scheduler
      @logger = logger
      @clock = clock
      @sleeper = sleeper

      @plan_date = nil          # 現在計画中の日付
      @punch_plans = {}         # kind => PunchPlan（対象日のみ）
      @last_refresh_at = nil    # 最後に sukesan を再取得した時刻
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
    #   日付変化 → 計画作成 / refresh 間隔 → 退勤再計算 / due 判定 → 打刻。
    def tick
      now = @clock.call
      ensure_day_plan(now)
      refresh_if_due(now)
      fire_due_punches(now)
    end

    # 指定日の計画を組み立てて返す（`punch plan` のドライラン表示にも使う）。
    # events を渡さなければ sukesan から取得（失敗時はフォールバック）。
    def build_day_plan(date:, events: :fetch)
      out_plan = plan_clock_out(date: date, events: events)
      {
        date: date,
        target?: @calendar.target?(date),
        reason: @calendar.reason(date),
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
    end

    # 起動時・日付変化時に当日計画を作る。非対象日は計画なし（翌日待ち）。
    def ensure_day_plan(now)
      today = now.to_date
      return if @plan_date == today

      @plan_date = today
      @punch_plans = {}
      @last_refresh_at = nil
      @wake_scheduler.reset!

      reason = @calendar.reason(today)
      if reason
        @logger.info("#{today} は対象日ではないため計画しません（#{reason}）。翌日を待機します。")
        # 計画なし＝targets は空。前日の予約が残っていれば消す（manage_wake 有効時のみ pmset に触る）。
        reschedule_wakes(now)
        return
      end

      in_target = in_target_at(today)
      @punch_plans[:in] = PunchPlan.new(kind: :in, target_at: in_target, done: false,
                                        plan_detail: "所定#{@config.clock_in_time}+揺らぎ")
      @logger.info("出勤目標を設定: #{fmt(in_target)}")

      out = plan_clock_out(date: today, events: :fetch)
      set_out_plan(out, now)
      reschedule_wakes(now)
    end

    # refresh 間隔ごとに sukesan を再取得して退勤目標を再計算する。
    def refresh_if_due(now)
      return unless @punch_plans.key?(:out)
      return if @punch_plans[:out].done? # 退勤済みなら再取得不要

      interval = @config.calendar_refresh_interval_minutes * 60
      return if @last_refresh_at && (now - @last_refresh_at) < interval

      out = plan_clock_out(date: now.to_date, events: :fetch)
      before = @punch_plans[:out].target_at
      set_out_plan(out, now)
      after = @punch_plans[:out].target_at

      reschedule_wakes(now) if after != before
    end

    # 退勤計画を @punch_plans[:out] に反映する。
    def set_out_plan(out, now)
      @last_refresh_at = now
      target = out[:target]
      existing = @punch_plans[:out]

      if existing && existing.target_at != target
        @logger.info("退勤目標を更新: #{fmt(existing.target_at)} → #{fmt(target)}（#{out[:summary]}）")
      elsif existing.nil?
        @logger.info("退勤目標を設定: #{fmt(target)}（#{out[:summary]}）")
      end

      done = existing&.done? || false
      @punch_plans[:out] = PunchPlan.new(kind: :out, target_at: target, done: done, plan_detail: out[:summary])
    end

    # due（目標<=現在<=目標+grace）の打刻を実行。grace 超過は警告してスキップ扱いにする。
    def fire_due_punches(now)
      grace = @config.daemon_late_grace_minutes * 60
      KINDS.each do |kind|
        pp = @punch_plans[kind]
        next if pp.nil? || pp.done?
        next if now < pp.target_at # まだ

        if now > pp.target_at + grace
          @logger.warn("#{label(kind)}目標 #{fmt(pp.target_at)} を#{@config.daemon_late_grace_minutes}分超過（現在 #{fmt(now)}）。" \
                       "誤時刻打刻を避けるため打刻せずスキップします。")
          pp.done = true
          next
        end

        execute_punch(kind, now)
        pp.done = true
      end
    end

    # 実際の打刻。トークン更新（CLI#run_punch 相当）→ Stamper#punch（window=0 で即時）。
    # 揺らぎは目標時刻に織込済みのため window は 0 で呼ぶ。冪等・対象日判定は Stamper に委ねる。
    def execute_punch(kind, now)
      if @token_store.needs_refresh?(now: now)
        @logger.info("トークンの有効期限が近いため再発行します")
        @token_store.refresh!(@client)
      end

      @stamper.punch(kind: kind, date: now.to_date, window_minutes: 0)
    rescue StandardError => e
      @logger.error("#{label(kind)}の打刻に失敗: #{e.class}: #{e.message}")
    end

    # 残っている（未実行の）当日打刻目標について wake を予約し直す。
    def reschedule_wakes(now)
      return unless @config.daemon_manage_wake

      targets = @punch_plans.values.reject(&:done?).map(&:target_at).select { |t| t > now }
      @wake_scheduler.reschedule(targets)
    end

    # 退勤の目標時刻を計算する。events==:fetch なら sukesan から取得（失敗時はフォールバック）。
    # 返り値: { target:, plan:(Plan or nil), summary:(String), error:(String or nil) }
    def plan_clock_out(date:, events:)
      default = clock_out_default_at(date)

      # 連動OFFなら sukesan には一切アクセスせず所定時刻（+揺らぎ）を使う。
      unless @config.calendar_enabled
        return { target: apply_jitter(default, date, :out), plan: nil,
                 summary: "カレンダー連動OFF（所定時刻）", error: nil }
      end

      error = nil
      evs =
        if events == :fetch
          begin
            @calendar_client.events(date: date)
          rescue CalendarClient::ApiError => e
            error = e.message
            nil
          end
        else
          events
        end

      if evs.nil?
        @logger&.warn("sukesan からのイベント取得に失敗しました（#{error}）。所定退勤時刻へフォールバックします。")
        summary = "sukesan 障害のため所定時刻へフォールバック"
        return { target: apply_jitter(default, date, :out), plan: nil, summary: summary, error: error }
      end

      plan = build_out_plan(evs, date, default)
      summary =
        if plan.source == :calendar
          "採用: #{event_label(plan.adopted_event)}"
        else
          "所定時刻（#{plan.fallback_reason}）"
        end

      { target: apply_jitter(plan.target_at, date, :out), plan: plan, summary: summary, error: nil }
    end

    def build_out_plan(events, date, default)
      ClockOutPlanner.new(exclude_keywords: @config.calendar_exclude_keywords)
                     .plan(events: events, date: date, default_clock_out: default)
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
