# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "time"

module Ak4Punch
  # ローカル常駐システム sukesan のカレンダーAPIクライアント。
  # 依存 gem を増やさないため Net::HTTP を使用。
  #
  #   GET <base>/api/v1/calendars/google/events[?date=YYYY-MM-DD]
  #   Authorization: Bearer <APIキー>   ※クエリでのキー渡しは不可
  #
  # loopback（127.0.0.1）限定・レート制限 60回/分。プロセス停止時は接続拒否。
  class CalendarClient
    class ApiError < StandardError; end

    EVENTS_PATH = "/api/v1/calendars/google/events"

    # 1件のイベント。時刻は Time（オフセット付き）または nil。
    Event = Struct.new(:id, :title, :starts_at, :ends_at, :location, :all_day, keyword_init: true)

    def initialize(base_url:, api_key:, open_timeout: 5, read_timeout: 5)
      @base_url = base_url
      @api_key = api_key
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # 指定日のイベント配列（Event）を返す。date 省略時はサーバ側の当日。
    def events(date: nil)
      path = EVENTS_PATH
      path += "?#{URI.encode_www_form(date: date.strftime('%Y-%m-%d'))}" if date
      json = request(:get, path)
      Array(json["events"]).map { |e| build_event(e) }
    end

    private

    def build_event(raw)
      Event.new(
        id: raw["id"],
        title: raw["title"],
        starts_at: parse_time(raw["starts_at"]),
        ends_at: parse_time(raw["ends_at"]),
        location: raw["location"],
        all_day: raw["all_day"] == true,
      )
    end

    # ISO8601（オフセット付き）をパース。オフセットは文字列の値を信頼する。
    def parse_time(str)
      return nil if str.nil? || str.to_s.strip.empty?

      Time.iso8601(str)
    rescue ArgumentError
      nil
    end

    def request(method, path)
      raise ApiError, "sukesan APIキー(SUKESAN_API_KEY)が未設定です" if @api_key.nil? || @api_key.to_s.strip.empty?

      uri = URI("#{@base_url.chomp('/')}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout

      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{@api_key}"

      parse_response(http.request(req))
    rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
      raise ApiError, "sukesan 通信エラー: #{e.class}: #{e.message}"
    end

    def parse_response(res)
      json = (JSON.parse(res.body) rescue nil)
      code = res.code.to_i

      if code != 200
        detail = json&.dig("error", "message") || json&.dig("error", "code") || res.body
        raise ApiError, "sukesan HTTP #{code}: #{detail}"
      end
      raise ApiError, "sukesan JSONパースに失敗: #{res.body}" if json.nil?

      json
    end
  end
end
