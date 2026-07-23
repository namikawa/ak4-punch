# frozen_string_literal: true

require "net/http"
require "openssl"
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
    # 一過性エラー（通信エラー・HTTP 5xx）。短いバックオフでリトライする対象。
    # ApiError の派生なので、呼び出し側の `rescue CalendarClient::ApiError` はそのまま機能する。
    class TransientError < ApiError; end

    EVENTS_PATH = "/api/v1/calendars/google/events"

    # 1件のイベント。時刻は Time（オフセット付き）または nil。
    Event = Struct.new(:id, :title, :starts_at, :ends_at, :location, :all_day, keyword_init: true)

    # retry_backoffs: 一過性エラー時に待機する秒の配列（要素数＝リトライ回数）。既定 [2, 4]（計3回試行）。
    # sleeper: 待機の副作用（テストで実 sleep を避けるため注入可能）。
    def initialize(base_url:, api_key:, open_timeout: 5, read_timeout: 5,
                   retry_backoffs: [2, 4], sleeper: Kernel.method(:sleep))
      @base_url = base_url
      @api_key = api_key
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @retry_backoffs = retry_backoffs
      @sleeper = sleeper
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

      attempt = 0
      begin
        send_request(path)
      rescue TransientError
        # 一過性エラー（通信エラー・HTTP 5xx）は短いバックオフを挟んで数回リトライし、
        # Google 側の瞬断などを吸収する。ユーザ待ちのない常駐処理なので数秒の待機は許容。
        # 恒久エラー(4xx)は send_request が ApiError を投げるためここには来ず、即 surface される。
        raise if attempt >= @retry_backoffs.length

        @sleeper.call(@retry_backoffs[attempt])
        attempt += 1
        retry
      end
    end

    # 1回分の HTTP 取得。通信エラーは一過性(TransientError)としてラップする。
    def send_request(path)
      uri = URI("#{@base_url.chomp('/')}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      # Net::HTTP は既定 max_retries=1 で、ReadTimeout/EOFError/ECONNRESET 等では
      # ここで暗黙に1回再試行する（バックオフなし）。本クラスの request のリトライと二重になり
      # 実リクエストが最大6回になるのを防ぐため、内蔵リトライは無効化して制御を一本化する。
      http.max_retries = 0

      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{@api_key}"

      parse_response(http.request(req))
    rescue SocketError, Timeout::Error, EOFError, OpenSSL::SSL::SSLError, SystemCallError => e
      raise TransientError, "sukesan 通信エラー: #{e.class}: #{e.message}"
    end

    def parse_response(res)
      json = (JSON.parse(res.body) rescue nil)
      code = res.code.to_i

      if code != 200
        detail = json&.dig("error", "message") || json&.dig("error", "code") || res.body
        # 5xx はサーバ/プロバイダ側の一過性障害としてリトライ対象、4xx は恒久エラーとして即 surface。
        error_class = code >= 500 ? TransientError : ApiError
        raise error_class, "sukesan HTTP #{code}: #{detail}"
      end
      raise ApiError, "sukesan JSONパースに失敗: #{res.body}" if json.nil?

      json
    end
  end
end
