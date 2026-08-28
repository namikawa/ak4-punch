# frozen_string_literal: true

require "yaml"
require "date"
require "uri"
require "ipaddr"

module Ak4Punch
  # 動作設定。接続情報（企業ID/トークン/エンドポイント）は .env、
  # 振る舞い（時刻/対象日/冪等性/トークン）は config.yml から読む。
  class Config
    class Error < StandardError; end

    # ランダム打刻ウィンドウの上限（分）。
    MAX_WINDOW_MINUTES = 30

    # 所定時刻（work.clock_in / work.clock_out）の書式。時 0〜23 / 分 00〜59 の "HH:MM"。
    TIME_FORMAT = /\A([01]?\d|2[0-3]):[0-5]\d\z/

    # 1日の分数（打刻目標が翌日にはみ出す設定を弾く判定に使う）。
    MINUTES_PER_DAY = 24 * 60

    # トークン再発行の閾値（日）の既定値と上限。
    # 上限が31日なのはトークンの有効期限が「1ヶ月と1日」で、これを超える閾値は
    # 「常に再発行し続ける」と同義で意味を持たないため。
    DEFAULT_TOKEN_REFRESH_THRESHOLD_DAYS = 7
    MAX_TOKEN_REFRESH_THRESHOLD_DAYS = 31

    # カレンダー連動デーモンの既定値。
    DEFAULT_EXCLUDE_KEYWORDS = %w[会食 懇親会 飲み会 打ち上げ 歓迎会 送別会 忘年会 新年会].freeze
    # 出勤側（朝の先頭イベントのスキップ）の除外キーワード。退勤側とは目的が違うため独立させる。
    DEFAULT_CLOCK_IN_EXCLUDE_KEYWORDS = %w[移動 私用].freeze
    DEFAULT_REFRESH_INTERVAL_MINUTES = 15
    # 定期再取得が何回連続で失敗したら Slack に通知するか
    # （DarkWake 中の無通信など一過性の失敗で鳴らさないための閾値）。
    DEFAULT_REFRESH_FAILURE_NOTIFY_THRESHOLD = 3
    DEFAULT_TICK_SECONDS = 30
    DEFAULT_WAKE_LEAD_MINUTES = 1
    DEFAULT_LATE_GRACE_MINUTES = 10
    DEFAULT_SUKESAN_BASE_URL = "http://127.0.0.1:3000"

    # URL として受理するスキーム（平文 http は sukesan のループバックだけ許可する）。
    ALLOWED_URL_SCHEMES = %w[http https].freeze

    # 休暇イベントのキーワードの既定値（AKASHI は休暇申請日でも打刻を受理するため、
    # カレンダー上の休暇イベントで打刻時刻を決めるのが誤打刻を防ぐ主手段）。
    DEFAULT_LEAVE_KEYWORDS = %w[休み 休暇].freeze

    attr_reader :base_url, :company_id,
                :clock_in_time, :clock_out_time,
                :clock_in_window, :clock_out_window,
                :weekdays_only, :skip_japanese_holidays,
                :exclude_dates, :extra_workdays,
                :check_existing, :token_path, :token_refresh_threshold_days,
                :sukesan_base_url, :sukesan_api_key,
                :calendar_enabled, :calendar_exclude_keywords, :calendar_clock_in_exclude_keywords,
                :calendar_refresh_interval_minutes,
                :calendar_refresh_failure_notify_threshold,
                :calendar_leave_keywords,
                :daemon_tick_seconds, :daemon_wake_lead_minutes,
                :daemon_manage_wake, :daemon_late_grace_minutes, :daemon_morning_wake_at,
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
      @token_refresh_threshold_days =
        threshold_days!(tok.fetch("refresh_threshold_days", DEFAULT_TOKEN_REFRESH_THRESHOLD_DAYS))

      # sukesan 接続情報（機密）は .env から。BASE_URL は既定でループバック。
      @sukesan_base_url = env_or(data, "SUKESAN_BASE_URL", "sukesan_base_url") || DEFAULT_SUKESAN_BASE_URL
      @sukesan_api_key  = ENV["SUKESAN_API_KEY"]

      # Slack Incoming Webhook URL（機密・.env のみ）。未設定なら通知機能は無効。
      @slack_webhook_url = ENV["SLACK_WEBHOOK_URL"]
      # 通知に付けるメンション（例: <@U04XXXXXX>）。任意・未設定なら付けない。
      @slack_mention = ENV["SLACK_MENTION"]

      # カレンダー連動（出勤・退勤時刻の動的決定）の振る舞い。
      cal = data["calendar"] || {}
      @calendar_enabled = cal.fetch("enabled", false)
      kw = cal["exclude_keywords"]
      @calendar_exclude_keywords = kw.nil? ? DEFAULT_EXCLUDE_KEYWORDS.dup : Array(kw).map(&:to_s)
      # 出勤側は「朝の先頭から飛ばすイベント」の判定に使う（移動・私用など、出社前の予定）。
      ikw = cal["clock_in_exclude_keywords"]
      @calendar_clock_in_exclude_keywords =
        ikw.nil? ? DEFAULT_CLOCK_IN_EXCLUDE_KEYWORDS.dup : Array(ikw).map(&:to_s)
      @calendar_refresh_interval_minutes =
        positive_int(cal.fetch("refresh_interval_minutes", DEFAULT_REFRESH_INTERVAL_MINUTES),
                     DEFAULT_REFRESH_INTERVAL_MINUTES)
      # 定期再取得の連続失敗が この回数に達したときだけ Slack に通知する
      # （回数 × refresh_interval_minutes ≒ 取得できていない時間）。
      @calendar_refresh_failure_notify_threshold =
        positive_int(cal.fetch("refresh_failure_notify_threshold", DEFAULT_REFRESH_FAILURE_NOTIFY_THRESHOLD),
                     DEFAULT_REFRESH_FAILURE_NOTIFY_THRESHOLD)

      # 休暇イベントの判定キーワード（タイトル部分一致・時間の閾値なし）。
      # 一致したイベントは業務イベントから除外され、その時間帯の外へ打刻時刻を押し出す。
      lkw = cal["leave_keywords"]
      @calendar_leave_keywords = lkw.nil? ? DEFAULT_LEAVE_KEYWORDS.dup : Array(lkw).map(&:to_s)

      # 常駐デーモンの振る舞い。
      dae = data["daemon"] || {}
      @daemon_tick_seconds       = positive_int(dae.fetch("tick_seconds", DEFAULT_TICK_SECONDS), DEFAULT_TICK_SECONDS)
      @daemon_wake_lead_minutes  = dae.fetch("wake_lead_minutes", DEFAULT_WAKE_LEAD_MINUTES).to_i.clamp(0, 60)
      @daemon_manage_wake        = dae.fetch("manage_wake", true)
      @daemon_late_grace_minutes = positive_int(dae.fetch("late_grace_minutes", DEFAULT_LATE_GRACE_MINUTES),
                                                DEFAULT_LATE_GRACE_MINUTES)
      # 翌営業日に Mac を起こす時刻("HH:MM")。出勤アンカーの下限（この時刻より前に始まる予定は
      # 出勤の締切に採用しない）も兼ねる。未設定(nil)なら起床も下限も所定出勤時刻になる
      # （＝所定より前に始まる予定はアンカーにならず、出勤のカレンダー連動は実質無効）。
      @daemon_morning_wake_at = dae["morning_wake_at"]

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
      validate_urls!
      validate_time!("work.clock_in", @clock_in_time)
      validate_time!("work.clock_out", @clock_out_time)
      # 任意項目。設定されている場合だけ書式を検証する（未設定＝従来動作）。
      validate_time!("daemon.morning_wake_at", @daemon_morning_wake_at) unless @daemon_morning_wake_at.nil?
      validate_punch_windows!
    end

    # 接続先 URL のスキームを検証する。
    #
    # なぜ起動時に弾くのか: HTTP クライアント（Client / CalendarClient / SlackNotifier）は
    # いずれも `use_ssl = (scheme == "https")` としているだけなので、.env の URL を
    # `http://` と書き間違えても誰も気づけないまま、アクセストークン・APIキー・
    # Webhook URL が平文で社外ホストへ飛ぶ。検証はこの1箇所に集約する。
    #
    # メッセージには URL 全体を出さない（SLACK_WEBHOOK_URL はパスそのものが秘密で、
    # このメッセージは punch.log に残る）。表示は「スキーム://ホスト」までに丸め、
    # スキーム・ホストが取れない場合は値を一切出さない。
    def validate_urls!
      validate_https_url!("AK4_BASE_URL(base_url)", @base_url)
      # Slack は未設定・空文字が正常（通知機能が無効になるだけ）なので、設定時のみ検証する。
      validate_https_url!("SLACK_WEBHOOK_URL", @slack_webhook_url) unless blank?(@slack_webhook_url)
      validate_sukesan_url!
    end

    def validate_https_url!(key, value)
      scheme, host = url_parts!(key, value)
      return if scheme == "https"

      raise Error, "#{key} は https の URL を指定してください（#{scheme}://#{host} は" \
                   "暗号化されず、アクセストークンや Webhook URL が平文で送信されます）。"
    end

    # sukesan はローカルの API なので平文 http を許すが、許すのはループバック宛だけにする
    # （既定は http://127.0.0.1:3000）。ループバック以外へ平文で投げると APIキーが露出する。
    def validate_sukesan_url!
      scheme, host = url_parts!("SUKESAN_BASE_URL", @sukesan_base_url)
      return if scheme == "https" || loopback_host?(host)

      raise Error, "SUKESAN_BASE_URL に http を指定できるのはループバック" \
                   "（localhost / 127.0.0.0/8 / ::1）宛のときだけです（#{scheme}://#{host}）。" \
                   "他ホストの sukesan を参照する場合は https を指定してください。"
    end

    # http/https の URL から [スキーム, ホスト] を取り出す。解釈できない値・ホストのない値・
    # http/https 以外のスキームはエラーにする。ホストは URI#hostname（IPv6 の角括弧を外した形）。
    def url_parts!(key, value)
      uri = URI.parse(value.to_s)
      scheme = uri.scheme&.downcase
      host = uri.hostname
      # 「http://」を書き忘れた値（例: atnd.ak4.jp/api）はここに来る。値は出さない
      # （どの環境変数が不正かは key で分かる）。
      if scheme.nil? || host.nil? || host.empty?
        raise Error, "#{key} を URL として解釈できません。https://ホスト名/… の形式で指定してください。"
      end

      return [scheme, host] if ALLOWED_URL_SCHEMES.include?(scheme)

      raise Error, "#{key} のスキームが不正です（#{scheme}://#{host}）。http または https を指定してください。"
    rescue URI::InvalidURIError
      raise Error, "#{key} を URL として解釈できません。https://ホスト名/… の形式で指定してください。"
    end

    # 平文 http を許すループバックのホストか（完全一致で判定する。
    # 部分一致にすると http://127.0.0.1.example.com のような外部ホストを通してしまう）。
    # IP は IPAddr で判定するため 127.0.0.0/8 全体（127.0.0.53 など）と
    # ::1 の展開表記（0:0:0:0:0:0:0:1）も正しく通る。
    def loopback_host?(host)
      return true if host.casecmp?("localhost")

      IPAddr.new(host).loopback?
    rescue IPAddr::Error
      false # ホスト名（DNS 名）は IP として解釈できない＝ループバックではない
    end

    # 所定時刻とウィンドウの組み合わせが打刻できる範囲に収まっているかを検証する
    # （書式検証を通した後に呼ぶこと。ここでは "HH:MM" として解釈できることを前提にする）。
    #
    # ① 翌日にはみ出す設定を拒否する: デーモンは日付が変わると前日の計画を破棄するため
    #    （Daemon#start_new_day）、翌日に出た目標は必ず未打刻になる。
    #    例: clock_out 23:59 + clock_out_window 5 → 翌日 00:04。
    #    カレンダー由来の目標は当日終了のイベントだけを対象にする（ClockOutPlanner）ので
    #    ここでは設定由来だけを見る。
    # ② 出勤の打刻締切（clock_in + clock_in_window）が退勤時刻以降になる設定を拒否する。
    #    実測では clock_in 17:50 / clock_out 18:00 / window 30 で出勤目標 18:14・退勤目標 18:10
    #    となり、先に来た退勤が「未出勤」で冪等スキップされ、出勤だけが記録される状態になった。
    #    なお休暇による全休判定（Daemon#full_leave?）が休暇イベントの有無を条件にしているのは、
    #    この種の設定ミスを「全休」として黙って打刻停止しないため。こちらは起動時に弾く役割を持つ。
    def validate_punch_windows!
      in_deadline = minutes_of_day(@clock_in_time) + @clock_in_window
      out_target = minutes_of_day(@clock_out_time) + @clock_out_window
      clock_out = minutes_of_day(@clock_out_time)

      if in_deadline >= MINUTES_PER_DAY
        raise Error, "出勤の打刻締切が翌日になります（work.clock_in #{@clock_in_time} + " \
                     "clock_in_window #{@clock_in_window}分 = #{format_minutes(in_deadline)}）。" \
                     "日付が変わると当日の計画は破棄されるため、当日に収まる値にしてください。"
      end
      if out_target >= MINUTES_PER_DAY
        raise Error, "退勤の打刻目標が翌日になります（work.clock_out #{@clock_out_time} + " \
                     "clock_out_window #{@clock_out_window}分 = #{format_minutes(out_target)}）。" \
                     "日付が変わると当日の計画は破棄されるため、当日に収まる値にしてください。"
      end
      return if in_deadline < clock_out

      raise Error, "出勤の打刻締切（work.clock_in #{@clock_in_time} + clock_in_window " \
                   "#{@clock_in_window}分 = #{format_minutes(in_deadline)}）が " \
                   "work.clock_out(#{@clock_out_time}) 以降になっています。" \
                   "退勤が出勤より先に来ると出勤だけが記録されるため、締切が退勤時刻より前になるようにしてください。"
    end

    # トークン再発行の閾値（日）を整数化して範囲を検証する。
    # 既定値へ黙ってフォールバックさせないのは、設定ミスに気づけないまま
    # 「打刻の直前に毎 tick 失敗して grace 超過で未打刻」という壊れ方をするため
    # （YAML に値なしで書くと nil が入り、TokenStore#needs_refresh? の乗算で NoMethodError になる）。
    # 小数は明示的に拒否する（Integer(7.9) は 7 を返すため、7.9 と書くと黙って 7 として通ってしまう。
    # 動作自体は 7 として正しくなるが「整数で指定してください」というメッセージと矛盾する）。
    # 文字列は基数10を明示して変換する（"0x1f" のような表記を弾くため）。
    def threshold_days!(value)
      days =
        case value
        when Integer then value
        when String then Integer(value, 10, exception: false)
        end
      return days if days && days.between?(0, MAX_TOKEN_REFRESH_THRESHOLD_DAYS)

      raise Error, "token.refresh_threshold_days は 0〜#{MAX_TOKEN_REFRESH_THRESHOLD_DAYS} の整数で" \
                   "指定してください（0 は期限切れまで再発行しない）: #{value.inspect}"
    end

    # 書式検証済みの "HH:MM" を「その日の 0:00 からの分」に変換する。
    def minutes_of_day(hhmm)
      h, m = hhmm.to_s.split(":").map(&:to_i)
      (h * 60) + m
    end

    # 分（0:00 起点）を "HH:MM" に戻す。翌日にはみ出す値には「翌日」を付ける。
    def format_minutes(total)
      prefix = total >= MINUTES_PER_DAY ? "翌日 " : ""
      format("%s%02d:%02d", prefix, (total % MINUTES_PER_DAY) / 60, total % 60)
    end

    # 所定時刻は文字列のまま保持し、目標時刻の算出時に "HH:MM" として解釈する。
    # 不正な値を黙って受理すると "oops" が 00:00（深夜打刻）になり、"25:00" は
    # 計画作成中の例外になって当日の打刻が全て止まる。どちらも気づきにくいため、
    # 起動時にエラーで停止して daemonctl log で即座に分かるようにする。
    # （config.yml で引用符を付けずに 09:30 と書くと YAML が数値に解釈するので、
    #  そのケースもここで弾かれる）
    def validate_time!(key, value)
      return if value.to_s.match?(TIME_FORMAT)

      raise Error, "#{key} の時刻指定が不正です（HH:MM 形式で指定してください）: #{value}"
    end

    def blank?(value) = Ak4Punch.blank?(value)
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
