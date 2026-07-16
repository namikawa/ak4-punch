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
  #
  # 送信失敗時はメッセージを pending キューに保持し、retry_pending（毎tick想定）で再送する。
  # スリープ明け直後の tick で Wi-Fi 未接続（DNS 解決失敗）でも、後の tick で届くようにするため。
  # 起床予約・スリープ抑止は一切しない（バッテリー影響ゼロ）。同期送信・非例外の性質は維持する。
  class SlackNotifier
    PREFIX = "[ak4-punch]"
    # pending キューの上限。超過時は古いものから捨てる（無制限にメモリを食わないため）。
    MAX_PENDING = 10

    # mention: 通知の先頭に付けるメンション（例: "<@U04XXXXXX>"）。nil/空なら付けない。
    # プライベートチャンネル運用でも確実にプッシュ通知を飛ばすためのオプション。
    def initialize(webhook_url:, mention: nil, logger: nil, open_timeout: 5, read_timeout: 5)
      @webhook_url = webhook_url
      @mention = normalize_mention(mention)
      @logger = logger
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @pending = [] # 送信に失敗したメッセージ（先頭が最古）
    end

    def enabled?
      !@webhook_url.nil? && !@webhook_url.to_s.strip.empty?
    end

    # メッセージを送信する。無効時は何もしない。失敗しても例外は上げない。
    # 失敗した場合は pending キューに保持し、以降の retry_pending で再送する。
    def notify(message)
      return unless enabled?

      # 初回失敗時のみ warn を出す（retry_pending の再失敗では静音）。
      enqueue_pending(message) unless deliver(message, warn_on_failure: true)
    end

    # pending に保持しているメッセージを先頭から順に再送する（毎tickから呼ばれる想定）。
    # 成功したらキューから除去して継続、失敗したら残して即終了（後続は次回に回す）。
    # 再失敗では warn を出さない（30秒毎のログスパム防止）。無効時は no-op。
    def retry_pending
      return unless enabled?
      return if @pending.empty?

      until @pending.empty?
        break unless deliver(@pending.first, warn_on_failure: false)

        @pending.shift
        @logger&.info("保留していた通知を再送しました。")
      end
    end

    private

    # メッセージを1件送信する。成功（2xx）なら true、失敗なら false を返す。例外は上げない。
    # warn_on_failure: true のときだけ失敗を warn ログに出す。
    def deliver(message, warn_on_failure:)
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
      return true if res.code.to_i.between?(200, 299)

      if warn_on_failure
        @logger&.warn("Slack通知に失敗しました（HTTP #{res.code}）。保留して再送します。")
      end
      false
    rescue StandardError => e
      if warn_on_failure
        @logger&.warn("Slack通知に失敗しました（#{e.class}: #{e.message}）。保留して再送します。")
      end
      false
    end

    # pending キューへ追加する。上限超過時は先頭（最古）から捨てて警告する。
    def enqueue_pending(message)
      @pending << message
      return if @pending.size <= MAX_PENDING

      dropped = @pending.size - MAX_PENDING
      @pending.shift(dropped)
      @logger&.warn("保留中の通知が上限（#{MAX_PENDING}件）を超えたため、古い#{dropped}件を破棄しました。")
    end

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
