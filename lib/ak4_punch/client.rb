# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "json"

module Ak4Punch
  # AKASHI 公開API クライアント（打刻・打刻取得・トークン再発行）。
  # 依存 gem を増やさないため Net::HTTP を使用。
  class Client
    class ApiError < StandardError; end

    attr_accessor :token

    # clock は現在時刻の取得（打刻期限の判定用）。テストで差し替えられるよう注入する。
    def initialize(base_url:, company_id:, token:, clock: -> { Ak4Punch.now })
      @base_url = base_url
      @company_id = company_id
      @token = token
      @clock = clock
    end

    # 打刻実行(6.6)。stampedAt は API 側で無視されるため送らない
    # （記録時刻＝サーバ受信時刻）。type: 11=出勤 / 12=退勤。
    # deadline: 指定すると接続確立後・送信直前に期限を再判定し、超過なら送らず中止する。
    # 期限判定が要るのは打刻 POST だけ（打刻取得・トークン再発行は記録時刻に影響しない）。
    def post_stamp(type:, timezone: Ak4Punch::JST, deadline: nil)
      json = request(:post, stamps_path, body: { token: @token, type: type, timezone: timezone },
                                         deadline: deadline)
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

    # 当日の最終打刻（stamped_at 昇順の最後）の種別を返す。打刻が無ければ nil。
    # 冪等・在席判定用。単純な「当日に同 type があるか」ではなくこれを使うことで、
    # 前営業日の退勤が当日日付に記録される日跨ぎ勤務でも、当日の勤務セッションを正しく判定できる。
    def latest_stamp_type(date:)
      latest = get_stamps(date: date).max_by { |s| s["stamped_at"].to_s }
      latest && latest["type"]
    end

    # アクセストークン再発行(6.9)。新 token と有効期限(Time)を返す。
    def reissue_token
      json = request(:post, "/token/reissue/#{@company_id}", body: { token: @token })
      resp = json["response"] || {}
      { token: resp["token"], expired_at: Ak4Punch.parse_akashi_time(resp["expired_at"]) }
    end

    private

    def stamps_path = "/#{@company_id}/stamps"

    def request(method, path, body: nil, deadline: nil)
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

      return parse_response(send_within_deadline(http, req, deadline)) if deadline

      parse_response(http.request(req))
    rescue SocketError, Timeout::Error, EOFError, OpenSSL::SSL::SSLError, SystemCallError => e
      # DeadlineExceeded はここに含めない（通信エラーではなく意図的な中止のため、そのまま上げる）。
      raise ApiError, "通信エラー: #{e.class}: #{e.message}"
    end

    # 打刻 POST の最終関門。接続確立（DNS+TCP+TLS）を先に済ませてから期限を再判定し、
    # 期限内だと確認できた直後にリクエストを書き出す。
    # 接続確立中にスリープすると、TCP の再送は復帰後も続き、macOS の monotonic クロックは
    # スリープ中に止まるので open_timeout（10秒）も生き残る。つまり「10秒で諦めるはず」の接続が
    # 実時間では何時間も後に成立し得るため、確立後にもう一度時計を見る必要がある。
    # ここまで来ると残るのは「判定 → リクエスト書き込み」の一瞬だけで、これは原理的に消せない残余。
    # 誤時刻打刻の防衛線は fire_due_punches の窓判定 → Stamper の冪等チェック後の判定 →
    # ここ（送信直前）の三段で、段階的に窓を狭めている。
    def send_within_deadline(http, req, deadline)
      http.start
      now = @clock.call
      if now > deadline
        raise DeadlineExceeded,
              "打刻期限を超過したため送信直前で中止しました" \
              "（期限 #{deadline.strftime('%H:%M:%S')}／現在 #{now.strftime('%H:%M:%S')}）"
      end

      http.request(req)
    ensure
      # 明示的に開いた接続は必ず閉じる（ブロック形式の start と違い自動では閉じないため）。
      http.finish if http.started?
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
  end
end
