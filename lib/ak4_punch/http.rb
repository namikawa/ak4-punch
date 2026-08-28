# frozen_string_literal: true

require "net/http"
require "uri"

module Ak4Punch
  # Net::HTTP の接続オブジェクトを組み立てる共通処理。
  # 依存 gem を増やさない方針のため HTTP クライアントは3つ（Client / CalendarClient /
  # SlackNotifier）とも Net::HTTP を直に使っており、その組み立てだけをここに集約する。
  # タイムアウトは用途ごとに違うので呼び出し側から渡す。
  #
  # ホストは URI#host ではなく URI#hostname（IPv6 の角括弧を外した形）を渡すこと。
  # URI#host は IPv6 を "[::1]" と角括弧付きで返し、Net::HTTP.new("[::1]", 3000) は
  # getaddrinfo が失敗して Socket::ResolutionError になる（hostname なら "::1" が渡り接続できる）。
  # sukesan はループバック運用で SUKESAN_BASE_URL に http://[::1]:3000 を設定できるため、
  # ここが実害の当事者になる。通常のホスト名では host == hostname で挙動は変わらないので、
  # 誤って host に戻しても普段は気づけない（spec/http_spec.rb と
  # spec/calendar_client_spec.rb の「Net::HTTP に渡すホスト」で回帰を検出する）。
  module Http
    module_function

    # uri: URI。open_timeout / read_timeout: 秒。
    # use_ssl はスキームから決める（https のときだけ true）。
    def build(uri, open_timeout:, read_timeout:)
      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout
      http
    end
  end
end
