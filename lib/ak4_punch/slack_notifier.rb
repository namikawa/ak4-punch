# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Ak4Punch
  # Slack Incoming Webhook への通知（異常時のみ使う）。
  #
  # 最重要制約: 通知の失敗（非2xx・通信エラー・タイムアウト）で例外を上げない。
  # 通知はあくまで補助であり、打刻処理を妨げてはならない。失敗は警告ログのみ。
  #
  # webhook_url が未設定（nil/空）なら通知機能は完全に無効（notify は no-op）。
  class SlackNotifier
    PREFIX = "[ak4-punch]"

    # mention: 通知の先頭に付けるメンション（例: "<@U04XXXXXX>"）。nil/空なら付けない。
    # プライベートチャンネル運用でも確実にプッシュ通知を飛ばすためのオプション。
    def initialize(webhook_url:, mention: nil, logger: nil, open_timeout: 5, read_timeout: 5)
      @webhook_url = webhook_url
      @mention = normalize_mention(mention)
      @logger = logger
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def enabled?
      !@webhook_url.nil? && !@webhook_url.to_s.strip.empty?
    end

    # メッセージを送信する。無効時は何もしない。失敗しても例外は上げない。
    def notify(message)
      return unless enabled?

      uri = URI(@webhook_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout

      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      text = [@mention, PREFIX, message].compact.join(" ")
      req.body = JSON.generate(text: text)

      res = http.request(req)
      unless res.code.to_i.between?(200, 299)
        @logger&.warn("Slack通知に失敗しました（HTTP #{res.code}）。打刻処理は継続します。")
      end
    rescue StandardError => e
      @logger&.warn("Slack通知に失敗しました（#{e.class}: #{e.message}）。打刻処理は継続します。")
    end

    private

    # メンション文字列を正規化する。素のメンバーID（U.../W...、先頭@も許容）が
    # 渡された場合は <@ID> 形式に整形する（.env 設定ミスの救済）。
    # "<@U...>" や "<!channel>" のような正しい形式はそのまま使う。
    def normalize_mention(mention)
      m = mention.to_s.strip
      return nil if m.empty?
      return "<@#{m.delete_prefix('@')}>" if m.match?(/\A@?[UW][A-Z0-9]+\z/)

      m
    end
  end
end
