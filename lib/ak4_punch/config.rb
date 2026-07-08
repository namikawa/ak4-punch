# frozen_string_literal: true

require "yaml"
require "date"

module Ak4Punch
  # 動作設定。接続情報（企業ID/トークン/エンドポイント）は .env、
  # 振る舞い（時刻/対象日/冪等性/トークン）は config.yml から読む。
  class Config
    class Error < StandardError; end

    # ランダム打刻ウィンドウの上限（分）と、opt-in時の既定値。
    MAX_WINDOW_MINUTES = 30
    DEFAULT_RANDOM_WINDOW_MINUTES = 5

    attr_reader :base_url, :company_id, :timezone,
                :clock_in_time, :clock_out_time,
                :clock_in_window, :clock_out_window,
                :weekdays_only, :skip_japanese_holidays,
                :exclude_dates, :extra_workdays,
                :check_existing, :token_path, :token_refresh_threshold_days

    def self.load(config_path:, root:)
      EnvFile.load(File.join(root, ".env"))
      data = File.exist?(config_path) ? (YAML.safe_load_file(config_path) || {}) : {}
      new(data: data, root: root)
    end

    def initialize(data:, root:)
      @base_url   = env_or(data, "AK4_BASE_URL", "base_url") || "https://atnd.ak4.jp/api/cooperation"
      @company_id = env_or(data, "AK4_COMPANY_ID", "company_id")
      @timezone   = data["timezone"] || Ak4Punch::JST

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
  end
end
