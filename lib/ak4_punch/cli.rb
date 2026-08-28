# frozen_string_literal: true

require "thor"
require "logger"
require "date"
require "rbconfig"
require "etc"

module Ak4Punch
  class CLI < Thor
    # LaunchAgent の Umask に指定する値。63 は 8 進の 077（＝本人以外に権限を与えない）。
    # plist の <integer> は10進しか表現できない（launchd.plist(5): "property lists do not
    # support encoding integers in octal"）ため、`077` と書くと 8 進 077 にはならず
    # 10 進 77（＝8進115）になり、group/other に読み取りが残ってしまう。必ず10進で書くこと。
    # デーモンが作るファイル（punch.log）にはカレンダーの予定タイトルが載るため、
    # 既定の 0644 ではなく本人だけが読める権限で作らせる（launchd.plist(5) の StandardOutPath:
    # ファイルが無い場合は Umask を反映した権限で作成される）。
    # 既存の punch.log の権限は umask では変わらないので、必要なら手で chmod する。
    UMASK_OWNER_ONLY = 0o077

    def self.exit_on_failure? = true

    class_option :config, type: :string, desc: "config.yml のパス（既定: <root>/config/config.yml）"
    class_option :dry_run, type: :boolean, default: false, desc: "POST せず動作予定のみ表示"
    class_option :force, type: :boolean, default: false, desc: "対象日判定・重複チェックを無視して打刻"

    # 出勤/退勤共通のランダム打刻オプション。
    def self.punch_options
      method_option :window, type: :numeric,
                             desc: "指定時刻から N 分以内のランダムな時刻に打刻（0=ちょうど・最大#{Config::MAX_WINDOW_MINUTES}）"
    end

    desc "clock_in", "出勤(type=11)を打刻する"
    map "in" => :clock_in
    punch_options
    def clock_in = run_punch(:in)

    desc "clock_out", "退勤(type=12)を打刻する"
    map "out" => :clock_out
    punch_options
    def clock_out = run_punch(:out)

    desc "status", "指定日（既定: 本日）の打刻状況を表示"
    method_option :date, type: :string, desc: "YYYY-MM-DD"
    def status
      app = build
      date = options[:date] ? Date.parse(options[:date]) : Ak4Punch.today
      stamps = app[:client].get_stamps(date: date)
      puts "#{date} の打刻: #{stamps.size} 件"
      stamps.each { |s| puts "  type=#{s['type']} stamped_at=#{s['stamped_at']}" }
    rescue StandardError => e
      abort "エラー: #{e.message}"
    end

    desc "refresh_token", "アクセストークンを再発行して保存する"
    def refresh_token
      app = build
      app[:store].refresh!(app[:client])
      puts "トークンを再発行しました。有効期限: #{Ak4Punch.format_akashi_time(app[:store].expired_at)}"
    rescue StandardError => e
      abort "エラー: #{e.message}"
    end

    desc "daemon", "カレンダー連動デーモンをフォアグラウンド実行（推奨・launchd常駐向け）"
    def daemon
      app = build
      daemon = build_daemon(app)
      daemon.run
    rescue StandardError => e
      abort "エラー: #{e.message}"
    end

    desc "plan", "当日（または指定日）の打刻計画をドライラン表示（sukesanへのGETのみ・AKASHIは触らない）"
    method_option :date, type: :string, desc: "YYYY-MM-DD"
    def plan
      cfg = load_config
      logger = build_logger
      date = options[:date] ? Date.parse(options[:date]) : Ak4Punch.today
      # 計画の組み立て（sukesan の取得を含む）を先に済ませる。取得失敗の警告ログは
      # DayPlanner が出すため、見出しより前に出るのが従来の並び。
      events, error = fetch_plan_events(cfg, date)
      day = DayPlanner.new(config: cfg, logger: logger).call(date: date, events: events, error: error)

      puts "==== #{date} の打刻計画 ===="
      reason = build_calendar(cfg).reason(date)
      if reason
        puts "対象日ではありません（#{reason}）。打刻しません。"
        return
      end

      print_plan(day, cfg)
    rescue StandardError => e
      abort "エラー: #{e.message}"
    end

    desc "launchd", "LaunchAgent plist と設置手順を出力（bin/daemonctl install が利用）"
    method_option :plist_only, type: :boolean, default: false,
                               desc: "plist XML のみを出力（ガイド文なし。daemonctl install 用）"
    def launchd
      root = project_root
      plist = build_launchd_plist(root)

      # --plist-only は plist XML だけを出力する（bin/daemonctl install がリダイレクトで使う）。
      if options[:plist_only]
        puts plist
        return
      end

      puts <<~GUIDE
        # ===== LaunchAgent（推奨・常駐デーモン）=====
        # 1) 下記 plist を ~/Library/LaunchAgents/com.ak4punch.daemon.plist に保存:
        mkdir -p ~/Library/LaunchAgents
        cat > ~/Library/LaunchAgents/com.ak4punch.daemon.plist <<'PLIST'
        #{plist.chomp}
        PLIST

        # 2) 読み込み（登録＋起動）:
        launchctl load -w ~/Library/LaunchAgents/com.ak4punch.daemon.plist

        # 3) 動作確認:
        launchctl list | grep com.ak4punch.daemon   # PID が付いていれば起動中
        tail -f #{root}/punch.log                     # ログ確認

        # 停止/再読込:
        #   launchctl unload ~/Library/LaunchAgents/com.ak4punch.daemon.plist
        #   launchctl load -w ~/Library/LaunchAgents/com.ak4punch.daemon.plist
        #
        # ※ 自動起床（pmset）を使う場合は先に `punch sudoers` を設定してください。
      GUIDE
    end

    desc "sudoers", "pmset を NOPASSWD 許可する sudoers 設定を出力（自動起床に必要）"
    def sudoers
      user = ENV["USER"] || Etc.getpwuid(Process.uid).name
      pmset = WakeScheduler::PMSET
      puts <<~GUIDE
        # ===== sudoers 設定（pmset の自動起床予約を無パスワードで許可）=====
        # デーモンが実行するのは起床予約の追加（`sudo -n pmset schedule wake <日時>`）だけです。
        # 予約状態の読み取り（`pmset -g sched`）は sudo なしで実行するため、許可は要りません。
        # 下記1行を /etc/sudoers.d/ak4-punch に設置してください（visudo で構文検証されます）:

        #{user} ALL=(root) NOPASSWD: #{pmset} schedule wake *

        #   ※ 末尾の `*` は日時の引数に一致します（sudoers は引数を1つに連結した文字列として
        #     照合します）。`wake` の後の空白まで含むパターンなので、引数のない
        #     `#{pmset} schedule wake` には一致しませんが、デーモンは必ず日時を渡すため問題ありません。

        # 設置手順:
        sudo visudo -f /etc/sudoers.d/ak4-punch
        #   → 上記の1行を貼り付けて保存
        #   → 以前の `#{pmset} schedule *` を設置済みの場合は、上記の行に置き換えてください
        #     （置き換えなくても許可範囲が広いだけなので、そのままでも動作は継続します）

        # 確認（許可内容を一覧表示するだけ。起床予約は作りません）:
        sudo -k -n -l
        #   → 「may run the following commands」の一覧に次の行があることを確認してください:
        #        (root) NOPASSWD: #{pmset} schedule wake *
        #   → 標準設定（sudoers の listpw=any）で「a password is required」で終了した場合は、
        #     NOPASSWD の行が1つも無い状態です。listpw を all/always に変えている環境では
        #     NOPASSWD が正しくあってもこう出るため、`sudo -k -l`（-n なし）で認証して一覧を見てください。
        #   ※ `-k` は直前の visudo で残った認証キャッシュを無視し、一覧を取得できるかどうかが
        #     キャッシュに左右されないようにするために付けます（デーモンは launchd 起動で
        #     キャッシュを使えないため、NOPASSWD が無いと必ず失敗します）。
        #   ※ `sudo -l <コマンド>` 形式は「そのコマンドが policy 上許可されているか」しか判定せず、
        #     NOPASSWD が付いているかを確認できないため使いません。

        # ※ 設定しない場合は config.yml の daemon.manage_wake を false にし、
        #   常時電源接続＋スリープ無効（システム設定 > ロック画面/バッテリー）で運用してください。
      GUIDE
    end

    desc "recheck", "稼働中デーモンに当日計画の再チェックを要求する（SIGUSR1送信）"
    def recheck
      # 用途: カレンダーに誤って休暇イベントを入れて打刻が止まった場合、
      # イベントを修正してからこのコマンドで即時に再判定させる。
      pid = Daemon.find_pid
      abort "デーモンが起動していません" if pid.nil?

      Process.kill("USR1", pid)
      puts "デーモン(PID #{pid})に再チェックを要求しました。ログ(punch.log)で結果を確認してください。"
    rescue StandardError => e
      abort "エラー: #{e.message}"
    end

    desc "version", "バージョン表示"
    def version = puts("ak4-punch #{Ak4Punch::VERSION}")

    private

    def run_punch(kind)
      app = build

      # トークンの有効期限が近ければ自動再発行（dry-run 時は行わない）
      if !options[:dry_run] && app[:store].needs_refresh?
        app[:logger].info("トークンの有効期限が近いため再発行します")
        app[:store].refresh!(app[:client])
      end

      window = resolve_window(kind, app[:config])
      # 打刻失敗は例外として上がり、下の rescue で abort する（結果の status は成功系のみ）。
      app[:stamper].punch(
        kind: kind, force: options[:force], dry_run: options[:dry_run], window_minutes: window,
      )
    rescue StandardError => e
      abort "エラー: #{e.message}"
    end

    # 実際に使うランダムウィンドウ（分）を決定する。
    # 優先順: --force(即時=0) > --window(明示・0も尊重) > 設定値(既定0)。
    def resolve_window(kind, cfg)
      return 0 if options[:force] # 手動強制はその場で即打刻

      cfg_window = kind == :in ? cfg.clock_in_window : cfg.clock_out_window
      w = options[:window] ? options[:window].to_i : cfg_window
      w.clamp(0, Config::MAX_WINDOW_MINUTES)
    end

    def build
      cfg = load_config
      logger = build_logger
      store = TokenStore.load(
        path: cfg.token_path,
        seed_token: cfg.token_seed,
        threshold_days: cfg.token_refresh_threshold_days,
      )
      if store.token.nil? || store.token.to_s.empty?
        abort "エラー: トークン(AK4_TOKEN)が未設定です。マイページで発行し .env に設定してください。"
      end
      client = Client.new(base_url: cfg.base_url, company_id: cfg.company_id, token: store.token)
      calendar = build_calendar(cfg)
      stamper = Stamper.new(config: cfg, client: client, calendar: calendar, logger: logger)
      { config: cfg, logger: logger, store: store, client: client, calendar: calendar, stamper: stamper }
    end

    # デーモン一式を app（build の戻り）から組み立てる。
    def build_daemon(app)
      cfg = app[:config]
      Daemon.new(
        config: cfg,
        stamper: app[:stamper],
        calendar: app[:calendar],
        calendar_client: build_calendar_client(cfg),
        token_store: app[:store],
        client: app[:client],
        wake_scheduler: WakeScheduler.new(lead_minutes: cfg.daemon_wake_lead_minutes, logger: app[:logger]),
        logger: app[:logger],
        # URL 未設定なら no-op の通知器になる（異常時のみ Slack 通知）。
        notifier: SlackNotifier.new(webhook_url: cfg.slack_webhook_url, mention: cfg.slack_mention,
                                    logger: app[:logger]),
      )
    end

    def build_calendar_client(cfg)
      CalendarClient.new(base_url: cfg.sukesan_base_url, api_key: cfg.sukesan_api_key)
    end

    # `punch plan` 用の sukesan 取得。戻り値: [イベント配列(or nil), エラーメッセージ(or nil)]。
    # 連動OFF なら取得しない（nil ＝ 未取得。DayPlanner が所定時刻の計画を作る）。
    # 取得失敗も所定時刻フォールバックの計画になるのでここで握る。デーモンと違い
    # 連続失敗の集計・通知は不要なので、メッセージを返すだけにする。
    def fetch_plan_events(cfg, date)
      return [nil, nil] unless cfg.calendar_enabled

      [build_calendar_client(cfg).events(date: date), nil]
    rescue CalendarClient::ApiError => e
      [nil, e.message]
    end

    # LaunchAgent plist（デーモン常駐用）。ruby の PATH はビルド時に解決する。
    #
    # plist に埋め込むパスは XML エスケープする。`&` や `<` を含むディレクトリに置いた場合、
    # そのまま補間すると plist が XML として壊れ、daemonctl install が壊れた plist を
    # 設置してしまう（launchd が読めないだけで、原因はログにも出ず分かりにくい）。
    def build_launchd_plist(root)
      ruby_bindir = xml_escape(File.dirname(RbConfig.ruby))
      exec_path = xml_escape(File.join(root, "bin", "punch"))
      root_path = xml_escape(root)
      <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>com.ak4punch.daemon</string>
          <key>ProgramArguments</key>
          <array>
            <string>#{exec_path}</string>
            <string>daemon</string>
          </array>
          <key>WorkingDirectory</key>
          <string>#{root_path}</string>
          <key>EnvironmentVariables</key>
          <dict>
            <key>PATH</key>
            <string>#{ruby_bindir}:/usr/bin:/bin:/usr/sbin:/sbin</string>
            <key>LANG</key>
            <string>ja_JP.UTF-8</string>
          </dict>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>Umask</key>
          <integer>#{UMASK_OWNER_ONLY}</integer>
          <key>StandardOutPath</key>
          <string>#{root_path}/punch.log</string>
          <key>StandardErrorPath</key>
          <string>#{root_path}/punch.log</string>
        </dict>
        </plist>
      PLIST
    end

    # plist の <string> に入れる値をエスケープする。
    # `&` を最初に置換すること（後に回すと、他の置換で入れた `&amp;` の `&` を
    # さらに `&amp;amp;` にしてしまう）。
    def xml_escape(value)
      value.to_s
           .gsub("&", "&amp;")
           .gsub("<", "&lt;")
           .gsub(">", "&gt;")
           .gsub('"', "&quot;")
    end

    # `punch plan` の計画（DayPlanner::DayPlan）を人間可読で出力する。
    # 見出しと対象日判定は plan コマンド側にある（WorkCalendar が要るため）。
    def print_plan(day, cfg)
      print_leave_periods(day)

      if day.full_leave?
        puts "全休: 休暇イベントで当日の勤務時間がなくなるため、この日は打刻しません"
        return
      end

      print_in_plan(day, cfg)
      puts
      print_out_plan(day, cfg)
    end

    # 休暇として扱ったイベントの一覧。キーワード部分一致・時間の閾値なしで拾うため
    # 「休み明けMTG」のようなタイトルも休暇になる。取りこぼし・拾いすぎに気づけるよう、
    # 半休の日（通常の計画を表示する日）でも必ず併記する。
    def print_leave_periods(day)
      periods = day.leaves.periods
      return if periods.nil? || periods.empty?

      puts "[休暇として扱ったイベント]"
      periods.each { |p| puts "  #{p.range_label} #{p.event.display_title}" }
      puts "  ※ 出勤締切・退勤基準がこの時間帯に入っていたら、時間帯の外へ押し出します"
      puts
    end

    # `punch plan` の退勤側（カレンダー連動の判断根拠＋基準時刻と目標）を出力する。
    def print_out_plan(day, cfg)
      puts "[退勤]"
      plan = day.clock_out.plan
      if day.clock_out.error
        puts "カレンダー取得: 失敗（#{day.clock_out.error}）→ 所定退勤時刻へフォールバック"
      elsif !cfg.calendar_enabled
        puts "カレンダー連動: OFF（config の calendar.enabled=false）→ 所定退勤時刻"
      elsif plan
        print_events("取得イベント（当日・終了時刻ありのみ・終了昇順／休暇イベントは除外済み）:",
                     plan.considered_events, plan)
        puts
        if plan.source == :calendar
          puts "採用イベント: #{plan.adopted_event.display_title}（終了 #{plan.adopted_event.ends_at.strftime('%H:%M')}）"
          puts "フォールバック: #{plan.fallback_reason}" if plan.fallback_reason
        else
          puts "採用イベントなし → 所定退勤時刻（理由: #{plan.fallback_reason}）"
        end
      end

      puts
      puts "退勤基準: #{day.clock_out.base.strftime('%H:%M:%S')}"
      print_leave_shifts(day.clock_out.leave_shifts)
      out_window = cfg.clock_out_window.positive? ? "+0〜#{cfg.clock_out_window}分揺らぎ" : ""
      puts "退勤目標: #{day.clock_out.target.strftime('%H:%M:%S')}#{out_window.empty? ? '' : "（#{out_window}）"}"
    end

    # `punch plan` の出勤側（カレンダー連動の判断根拠＋打刻締切と目標）を出力する。
    # 出勤は「締切 −0〜N分揺らぎ」で決まるため、退勤側と違い締切も表示する。
    def print_in_plan(day, cfg)
      puts "[出勤]"
      plan = day.clock_in.plan
      if day.clock_in.error
        puts "カレンダー取得: 失敗（#{day.clock_in.error}）→ 所定出勤時刻へフォールバック"
      elsif !cfg.calendar_enabled
        puts "カレンダー連動: OFF（config の calendar.enabled=false）→ 所定出勤時刻"
      elsif plan
        # 一覧は「下限より前で対象外にした分」も含めて開始昇順に並べ直す（採否はマークで示す）。
        print_events("取得イベント（当日・開始時刻ありのみ・開始昇順／休暇イベントは除外済み）:",
                     (plan.too_early_events + plan.considered_events).sort_by(&:starts_at),
                     plan, too_early: plan.too_early_events)
        puts
        if plan.source == :calendar
          puts "採用イベント: #{plan.adopted_event.display_title}（開始 #{plan.adopted_event.starts_at.strftime('%H:%M')}）"
          puts "フォールバック: #{plan.fallback_reason}" if plan.fallback_reason
        else
          puts "採用イベントなし → 所定の出勤締切（理由: #{plan.fallback_reason}）"
        end
      end

      puts
      deadline = day.clock_in.deadline
      adopted = plan&.adopted_event
      shifts = day.clock_in.leave_shifts
      note =
        if shifts && !shifts.empty?
          "休暇の時間帯の外へ後ろ倒し"
        elsif adopted && deadline == adopted.starts_at
          "採用イベントの開始"
        else
          "所定 #{cfg.clock_in_time} + ウィンドウ#{cfg.clock_in_window}分"
        end
      puts "打刻締切: #{deadline.strftime('%H:%M:%S')}（#{note}）"
      print_leave_shifts(shifts)
      in_window = cfg.clock_in_window.positive? ? "締切 −0〜#{cfg.clock_in_window}分揺らぎ" : "揺らぎなし"
      puts "出勤目標: #{day.clock_in.target.strftime('%H:%M:%S')}（#{in_window}）"
    end

    # 休暇による押し出しの根拠（どのイベントで、どこからどこへ動かしたか）。
    def print_leave_shifts(shifts)
      Array(shifts).each { |s| puts "  #{s.label}" }
    end

    # 判定に使ったイベント一覧を採否のマーク付きで出力する（出勤・退勤で共通）。
    # マークの判定順は「採用 → 除外 → 早すぎ → 対象外」。退勤側は「早すぎ」の概念がなく
    # too_early が空になるので、従来どおり「採用 → 除外 → 対象外」の結果になる。
    # 開始・終了はどちらも &. で参照する。出勤側の一覧は終了時刻なしのイベントを、
    # 退勤側の一覧は開始時刻なしのイベントを含みうるため（各 Planner が必須にしているのは
    # 自分が使う側の時刻だけ）。
    def print_events(heading, events, plan, too_early: [])
      puts heading
      if events.empty?
        puts "  (対象イベントなし)"
        return
      end

      events.each do |ev|
        mark =
          if ev.equal?(plan.adopted_event) then "採用 ←"
          elsif same_event?(plan.excluded_events, ev) then "除外"
          elsif same_event?(too_early, ev) then "早すぎ"
          else "対象外"
          end
        puts "  #{ev.starts_at&.strftime('%H:%M')}-#{ev.ends_at&.strftime('%H:%M')} #{ev.display_title}  [#{mark}]"
      end
    end

    # イベント一覧のマーク判定。sukesan が id を返さない（nil）ことがあり、Event は Struct で
    # == が値比較になるため、id や == ではなくオブジェクト同一性で照合する
    # （Planner が返す配列は取得したイベント配列と同じオブジェクトを保持している）。
    def same_event?(list, event) = list.any? { |e| e.equal?(event) }

    def build_calendar(cfg)
      WorkCalendar.new(
        weekdays_only: cfg.weekdays_only,
        skip_japanese_holidays: cfg.skip_japanese_holidays,
        exclude_dates: cfg.exclude_dates,
        extra_workdays: cfg.extra_workdays,
      )
    end

    def build_logger
      logger = Logger.new($stdout)
      logger.formatter = ->(_severity, time, _prog, msg) { "[#{time.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}\n" }
      logger
    end

    def load_config
      Config.load(
        config_path: options[:config] || File.join(project_root, "config", "config.yml"),
        root: project_root,
      )
    end

    def project_root = File.expand_path("../..", __dir__)
  end
end
