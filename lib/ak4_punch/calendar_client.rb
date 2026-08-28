# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "json"
require "time"
require "date" # Date._iso8601（オフセットの有無の判定）で使う

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

    # 形式不正のエラーメッセージに載せる値の最大長（超過分は切り詰める）。
    # 応答本文をそのまま全部載せるとログ・Slack が読めなくなるため。
    MAX_DETAIL_LENGTH = 200

    # 「nil か文字列」であることを検証するイベントのフィールド。下流が String 前提で扱うものだけを挙げる。
    #   title             … LeaveSchedule のキーワード判定（include?）と display_title（empty?）
    #   starts_at/ends_at … parse_time が Time.iso8601 に渡す（rescue は ArgumentError のみなので
    #                       数値だと TypeError が素通しし、定期再取得が毎 tick 例外になる）
    # id は意図的に検証しない: 数値で返る可能性があり、型に依存した処理もしていない
    # （実在の応答を弾かない側に倒す）。
    # キー自体が無い場合は nil 扱いで正常（実際に starts_at を持たない応答がある）。
    STRING_FIELDS = %w[title starts_at ends_at].freeze

    # 「オフセット付き ISO8601 の日時として解析できる文字列」であることまで検証するフィールド
    # （STRING_FIELDS の部分集合）。
    # 型が String でも中身が壊れていると parse_time が ArgumentError を rescue して nil を返すため、
    # そのイベントが ClockOutPlanner の対象から静かに落ち、退勤基準が所定時刻へ巻き戻る
    # （日中の再取得でこれが起きると、20:00 だった目標が 18:0x になり grace 内なら早期退勤する）。
    # 取得失敗（ApiError）にすれば refresh_if_due が既存目標を維持するので、
    # 「定期再取得の失敗では打刻目標を所定時刻へ巻き戻さない」（過去バグ 5843f72）と挙動が揃う。
    # nil・空文字・空白のみは parse_time が意図的に nil として扱うので正常のまま（判定は blank_time? で共有）。
    #
    # オフセットの有無も検証する。parse_time は「ISO8601（オフセット付き）を JST に正規化する」ことを
    # 前提に書かれている（海外タイムゾーンの招待は +09:00 以外のオフセットで届く）が、
    # Time.iso8601 はオフセットなしの日時（"2026-07-10T10:00:00"）も受理してホストのタイムゾーンで
    # 解釈してしまう。TZ が JST でない環境では時刻がずれるため、「日付・時刻ロジックはすべて JST 基準」
    # という不変条件を境界で強制する。検証を parse_time より厳しくするのは意図的で、
    # parse_time は寛容なまま残し、契約の強制はこの入口だけに置く。
    #
    # sukesan は Time#iso8601 の出力（常にオフセット付き）か null しか返さない
    # （終日イベントも Time.parse 経由で 00:00:00+09:00 になる）ため、この検証で実在の応答は弾かれない。
    TIME_FIELDS = %w[starts_at ends_at].freeze

    # 1件のイベント。時刻は JST に正規化済みの Time または nil。
    Event = Struct.new(:id, :title, :starts_at, :ends_at, :all_day, keyword_init: true) do
      # ログ・CLI 表示用のタイトル。nil と空文字はプレースホルダに置き換える。
      def display_title = title.nil? || title.empty? ? "(タイトルなし)" : title
    end

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
      extract_events(request(path)).map { |e| build_event(e) }
    end

    private

    # 応答の形を検証して events の配列を取り出す。
    # HTTP 200 でも形が違うことはあり、`Array(json["events"])` で黙って [] に潰すと
    # 「予定なし」の成功として扱われる（休暇情報が空で上書きされ、休暇日の防御が静かに外れる）。
    # 要素が Hash でない場合、あるいは要素内部のフィールドの型が違う場合は、build_event や
    # 下流（parse_time の Time.iso8601 / LeaveSchedule のキーワード判定）が TypeError・NoMethodError を
    # 投げる。これらは Daemon#fetch_events の `rescue CalendarClient::ApiError` を通らないため、
    # 定期再取得の経路では tick が毎回 fire_due_punches に到達せず、打刻が無通知のまま止まる。
    # どちらも一過性の通信障害ではなく恒久的な不整合なので、リトライしない ApiError にして
    # Daemon の既存の取得失敗経路（連続失敗カウント・所定時刻フォールバック・通知）に載せる。
    # 空配列は「予定なし」として正常。
    def extract_events(json)
      invalid_response!("オブジェクトではありません: #{summarize(json)}") unless json.is_a?(Hash)
      invalid_response!("events がありません: #{summarize(json)}") unless json.key?("events")

      events = json["events"]
      invalid_response!("events が配列ではありません: #{summarize(events)}") unless events.is_a?(Array)

      events.each_with_index do |raw, i|
        invalid_response!("events[#{i}] がオブジェクトではありません: #{summarize(raw)}") unless raw.is_a?(Hash)

        validate_event_fields!(raw, i)
      end
      events
    end

    # 1件のイベントのフィールドの型を検証する（下流が型に依存して扱うものだけ・詳細は STRING_FIELDS）。
    def validate_event_fields!(raw, index)
      STRING_FIELDS.each do |field|
        value = raw[field]
        next if value.nil? || value.is_a?(String)

        invalid_response!("events[#{index}].#{field} が文字列ではありません: #{summarize(value)}")
      end

      # 型が String でも、日時として読めない値・オフセットのない値は取得失敗にする（詳細は TIME_FIELDS）。
      TIME_FIELDS.each do |field|
        value = raw[field]
        next if blank_time?(value)

        reason = time_field_error(value)
        invalid_response!("events[#{index}].#{field} #{reason}: #{summarize(value)}") if reason
      end

      all_day = raw["all_day"]
      return if all_day.nil? || all_day == true || all_day == false

      # build_event は `== true` で潰すため例外にはならないが、"true" のような値を黙って
      # all_day=false として扱うと終日イベントを通常の予定として打刻判定に使ってしまう。
      invalid_response!("events[#{index}].all_day が真偽値ではありません: #{summarize(all_day)}")
    end

    # parse_time が nil として扱う値（nil・空文字・空白のみ）。
    # parse_time と同じ述語（Ak4Punch.blank?）を共有しているので判定は食い違わない。
    # 別々に書くと「検証は通るのに parse_time が nil にする」あるいはその逆が起きるため、
    # 片方だけ条件を変えないこと（変えるなら Ak4Punch.blank? を両方が使う形を保つ）。
    def blank_time?(value) = Ak4Punch.blank?(value)

    # 時刻フィールドが不正な理由（正常なら nil）。メッセージに埋めて位置と併せて示す。
    def time_field_error(value)
      return "が日時として解析できません" unless parsable_time?(value)
      return "にタイムゾーンオフセットがありません" unless offset_specified?(value)

      nil
    end

    # parse_time と同じ Time.iso8601 で解析できるか（STRING_FIELDS の検証を先に通すので String 前提）。
    def parsable_time?(value)
      Time.iso8601(value)
      true
    rescue ArgumentError
      false
    end

    # ISO8601 にタイムゾーンオフセットが含まれているか。
    # Time.iso8601 はオフセットなしでも成功してホストのタイムゾーンで解釈するため、
    # 解析結果ではなく元の文字列の構成要素で判定する。Date._iso8601 は解析できた要素をキーに持つ
    # Hash（解析できない入力では空 Hash、実装によっては nil）を返し、オフセット付きなら :offset を含む
    # （"Z"・"+0900"・"+09:00"・小数秒付き いずれも :offset が入ることを実測で確認済み）。
    def offset_specified?(value)
      parts = Date._iso8601(value)
      parts.is_a?(Hash) && parts.key?(:offset)
    end

    def invalid_response!(detail)
      raise ApiError, "sukesan 応答の形式が不正です（#{detail}）"
    end

    # エラーメッセージに載せる値の要約（長すぎる応答を切り詰める）。
    def summarize(value)
      text = value.inspect
      text.length > MAX_DETAIL_LENGTH ? "#{text[0, MAX_DETAIL_LENGTH]}…" : text
    end

    def build_event(raw)
      Event.new(
        id: raw["id"],
        title: raw["title"],
        starts_at: parse_time(raw["starts_at"]),
        ends_at: parse_time(raw["ends_at"]),
        all_day: raw["all_day"] == true,
      )
    end

    # ISO8601（オフセット付き）をパースし、JST に正規化する（瞬間は変えない）。
    # Google カレンダーはイベント毎にタイムゾーンを持てるため、海外タイムゾーンの招待では
    # +09:00 以外のオフセットで届く。そのまま下流に渡すと to_date が JST の日付とずれ、
    # 当日判定（ClockOutPlanner）や表示が狂うので、境界であるここで揃えておく。
    def parse_time(str)
      return nil if Ak4Punch.blank?(str)

      Time.iso8601(str).getlocal(Ak4Punch::JST)
    rescue ArgumentError
      nil
    end

    def request(path)
      raise ApiError, "sukesan APIキー(SUKESAN_API_KEY)が未設定です" if Ak4Punch.blank?(@api_key)

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
      http = Ak4Punch::Http.build(uri, open_timeout: @open_timeout, read_timeout: @read_timeout)
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
