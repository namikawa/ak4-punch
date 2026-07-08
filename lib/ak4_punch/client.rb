# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "time"

module Ak4Punch
  # AKASHI 公開API クライアント（打刻・打刻取得・トークン再発行）。
  # 依存 gem を増やさないため Net::HTTP を使用。
  class Client
    class ApiError < StandardError; end

    attr_accessor :token

    def initialize(base_url:, company_id:, token:)
      @base_url = base_url
      @company_id = company_id
      @token = token
    end

    # 打刻実行(6.6)。stampedAt は API 側で無視されるため送らない
    # （記録時刻＝サーバ受信時刻）。type: 11=出勤 / 12=退勤。
    def post_stamp(type:, timezone: Ak4Punch::JST)
      json = request(:post, stamps_path, body: { token: @token, type: type, timezone: timezone })
      resp = json["response"] || {}
      { type: resp["type"], stamped_at: resp["stampedAt"], staff_id: resp["staff_id"] }
    end

    # 指定日の打刻情報取得(6.7)。打刻配列を返す。
    def get_stamps(date:)
      query = URI.encode_www_form(
        token: @token,
        start_date: date.strftime("%Y%m%d000000"),
        end_date: date.strftime("%Y%m%d235959"),
      )
      json = request(:get, "#{stamps_path}?#{query}")
      json.dig("response", "stamps") || []
    end

    # 指定日に存在する打刻種別(type)の一覧。冪等チェック用。
    def stamped_types(date:)
      get_stamps(date: date).map { |s| s["type"] }
    end

    # アクセストークン再発行(6.9)。新 token と有効期限(Time)を返す。
    def reissue_token
      json = request(:post, "/token/reissue/#{@company_id}", body: { token: @token })
      resp = json["response"] || {}
      { token: resp["token"], expired_at: parse_time(resp["expired_at"]) }
    end

    private

    def stamps_path = "/#{@company_id}/stamps"

    def request(method, path, body: nil)
      uri = URI("#{@base_url.chomp('/')}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 20

      req =
        case method
        when :get  then Net::HTTP::Get.new(uri)
        when :post then Net::HTTP::Post.new(uri)
        else raise ArgumentError, "unsupported method: #{method}"
        end

      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end

      parse_response(http.request(req))
    rescue SocketError, Timeout::Error, Errno::ECONNREFUSED => e
      raise ApiError, "通信エラー: #{e.class}: #{e.message}"
    end

    def parse_response(res)
      json = (JSON.parse(res.body) rescue nil)
      raise ApiError, "HTTP #{res.code}: #{res.body}" if res.code.to_i != 200
      raise ApiError, "JSONパースに失敗: #{res.body}" if json.nil?

      unless json["success"] == true
        messages = Array(json["errors"]).map { |e| e["message"] || e.inspect }.join("; ")
        raise ApiError, "APIエラー: #{messages}"
      end
      json
    end

    def parse_time(str)
      return nil if str.nil? || str.to_s.strip.empty?

      Time.strptime("#{str} +0900", "%Y/%m/%d %H:%M:%S %z")
    rescue ArgumentError
      nil
    end
  end
end
