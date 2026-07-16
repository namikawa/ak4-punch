# frozen_string_literal: true

require "yaml"
require "date"

module Ak4Punch
  # 動作設定。接続情報（企業ID/トークン/エンドポイント）は .env、
  # 振る舞い（時刻/対象日/冪等性/トークン）は config.yml から読む。
  class Config
    class Error < StandardError; end

    # ランダム打刻ウィンドウの上限（分）。
    MAX_WINDOW_MINUTES = 30

    # カレンダー連動デーモンの既定値。
    DEFAULT_EXCLUDE_KEYWORDS = %w[会食 懇親会 飲み会 打ち上げ 歓迎会 送別会 忘年会 新年会].freeze
    DEFAULT_REFRESH_INTERVAL_MINUTES = 15
    DEFAULT_TICK_SECONDS = 30
    DEFAULT_WAKE_LEAD_MINUTES = 1
    DEFAULT_LATE_GRACE_MINUTES = 10
    DEFAULT_SUKESAN_BASE_URL = "http://127.0.0.1:3000"

    # 休暇の自動検知の既定値（AKASHI は休暇申請日でも打刻を受理するため、
    # カレンダー上の休暇イベント検知で打刻をスキップする）。
    DEFAULT_LEAVE_KEYWORDS = %w[休暇 有給 年休 全休 休み].freeze
    DEFAULT_LEAVE_MIN_DURATION_HOURS = 4

    attr_reader :base_url, :company_id,
                :clock_in_time, :clock_out_time,
                :clock_in_window, :clock_out_window,
                :weekdays_only, :skip_japanese_holidays,
                :exclude_dates, :extra_workdays,
                :check_existing, :token_path, :token_refresh_threshold_days,
                :sukesan_base_url, :sukesan_api_key,
                :calendar_enabled, :calendar_exclude_keywords, :calendar_refresh_interval_minutes,
                :calendar_leave_keywords, :calendar_leave_min_duration_hours,
                :daemon_tick_seconds, :daemon_wake_lead_minutes,
                :daemon_manage_wake, :daemon_late_grace_minutes,
                :slack_webhook_url, :slack_mention

    def self.load(config_path:, root:)
      EnvFile.load(File.join(root, ".env"))
      data = File.exist?(config_path) ? (YAML.safe_load_file(config_path) || {}) : {}
      new(data: data, root: root)
    end

    def initialize(data:, root:)
      @base_url   = env_or(data, "AK4_BASE_URL", "base_url") || "https://atnd.ak4.jp/api/cooperation"
      @company_id = env_or(data, "AK4_COMPANY_ID", "company_id")

      work = data["work"] || {}
      @clock_in_time  = work["clock_in"]  || "09:30"
      @clock_out_time = work["clock_out"] || "18:00"

      # ランダム打刻ウィンドウ（分）。指定時刻から N 分以内のランダムな時刻に打刻する。
      # 0 = 指定時刻ちょうど（従来動作）。in/out 共通の既定 + 個別上書き。上限 MAX_WINDOW_MINUTES。
      shared_window = work.fetch("random_window_minutes", 0)
      @clock_in_window  = clamp_window(work.fetch("clock_in_window",  shared_window))
      @clock_out_window = clamp_window(work.fetch("clock_out_window", shared_window))

      sched = data["schedule"] || {}
      @weekdays_only          = sched.fetch("weekdays_only", true)
      @skip_japanese_holidays = sched.fetch("skip_japanese_holidays", true)
      @exclude_dates  = Array(sched["exclude_dates"]).map  { |d| to_date(d) }
      @extra_workdays = Array(sched["extra_workdays"]).map { |d| to_date(d) }

      idem = data["idempotency"] || {}
      @check_existing = idem.fetch("check_existing", true)

      tok = data["token"] || {}
      @token_path = File.expand_path(tok["path"] || "config/token.json", root)
      @token_refresh_threshold_days = tok.fetch("refresh_threshold_days", 7)

      # sukesan 接続情報（機密）は .env から。BASE_URL は既定でループバック。
      @sukesan_base_url = env_or(data, "SUKESAN_BASE_URL", "sukesan_base_url") || DEFAULT_SUKESAN_BASE_URL
      @sukesan_api_key  = ENV["SUKESAN_API_KEY"]

      # Slack Incoming Webhook URL（機密・.env のみ）。未設定なら通知機能は無効。
      @slack_webhook_url = ENV["SLACK_WEBHOOK_URL"]
      # 通知に付けるメンション（例: <@U04XXXXXX>）。任意・未設定なら付けない。
      @slack_mention = ENV["SLACK_MENTION"]

      # カレンダー連動（退勤時刻の動的決定）の振る舞い。
      cal = data["calendar"] || {}
      @calendar_enabled = cal.fetch("enabled", false)
      kw = cal["exclude_keywords"]
      @calendar_exclude_keywords = kw.nil? ? DEFAULT_EXCLUDE_KEYWORDS.dup : Array(kw).map(&:to_s)
      @calendar_refresh_interval_minutes =
        positive_int(cal.fetch("refresh_interval_minutes", DEFAULT_REFRESH_INTERVAL_MINUTES),
                     DEFAULT_REFRESH_INTERVAL_MINUTES)

      # 休暇の自動検知（タイトル部分一致 + 終日または一定時間以上のイベント）。
      lkw = cal["leave_keywords"]
      @calendar_leave_keywords = lkw.nil? ? DEFAULT_LEAVE_KEYWORDS.dup : Array(lkw).map(&:to_s)
      @calendar_leave_min_duration_hours =
        positive_int(cal.fetch("leave_min_duration_hours", DEFAULT_LEAVE_MIN_DURATION_HOURS),
                     DEFAULT_LEAVE_MIN_DURATION_HOURS)

      # 常駐デーモンの振る舞い。
      dae = data["daemon"] || {}
      @daemon_tick_seconds       = positive_int(dae.fetch("tick_seconds", DEFAULT_TICK_SECONDS), DEFAULT_TICK_SECONDS)
      @daemon_wake_lead_minutes  = dae.fetch("wake_lead_minutes", DEFAULT_WAKE_LEAD_MINUTES).to_i.clamp(0, 60)
      @daemon_manage_wake        = dae.fetch("manage_wake", true)
      @daemon_late_grace_minutes = positive_int(dae.fetch("late_grace_minutes", DEFAULT_LATE_GRACE_MINUTES),
                                                DEFAULT_LATE_GRACE_MINUTES)

      validate!
    end

    # トークンの初期シード（マイページで発行して .env に設定した値）
    def token_seed = ENV["AK4_TOKEN"]

    private

    def env_or(data, env_key, data_key)
      v = ENV[env_key]
      v = data[data_key] if v.nil? || v.strip.empty?
      v
    end

    def validate!
      raise Error, "企業ID(AK4_COMPANY_ID)が未設定です。.env に設定してください。" if blank?(@company_id)
      raise Error, "エンドポイント(base_url)が未設定です。" if blank?(@base_url)
    end

    def blank?(value) = value.nil? || value.to_s.strip.empty?
    def to_date(value) = value.is_a?(Date) ? value : Date.parse(value.to_s)

    # 分を 0..MAX_WINDOW_MINUTES に丸める（負値は0、上限超過は上限）。
    def clamp_window(value) = value.to_i.clamp(0, MAX_WINDOW_MINUTES)

    # 正の整数に丸める（0以下や不正値は既定値にフォールバック）。
    def positive_int(value, default)
      n = value.to_i
      n.positive? ? n : default
    end
  end
end
