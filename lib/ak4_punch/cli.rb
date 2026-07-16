# frozen_string_literal: true

require "thor"
require "logger"
require "date"
require "rbconfig"
require "etc"

module Ak4Punch
  class CLI < Thor
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
      puts "トークンを再発行しました。有効期限: #{app[:store].expired_at&.strftime('%Y/%m/%d %H:%M:%S')}"
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
      calendar = build_calendar(cfg)
      calendar_client = build_calendar_client(cfg)
      daemon = Daemon.new(
        config: cfg, stamper: nil, calendar: calendar, calendar_client: calendar_client,
        token_store: nil, client: nil, wake_scheduler: nil, logger: logger,
      )
      date = options[:date] ? Date.parse(options[:date]) : Ak4Punch.today
      print_plan(daemon.build_day_plan(date: date), cfg)
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
        # デーモンが `sudo -n pmset schedule ...` を実行できるようにします。
        # 下記1行を /etc/sudoers.d/ak4-punch に設置してください（visudo で構文検証されます）:

        #{user} ALL=(root) NOPASSWD: #{pmset} schedule *

        # 設置手順:
        sudo visudo -f /etc/sudoers.d/ak4-punch
        #   → 上記の1行を貼り付けて保存

        # 確認（パスワードを聞かれずに実行できればOK）:
        sudo -n #{pmset} -g sched

        # ※ pmset の実パスは環境により異なる場合があります。上は #{pmset} を前提にしています。
        #   異なる場合は `which pmset` の結果に置き換えてください。
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
      result = app[:stamper].punch(
        kind: kind, force: options[:force], dry_run: options[:dry_run], window_minutes: window,
      )
      exit(1) if result.status == :error
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

    # LaunchAgent plist（デーモン常駐用）。ruby の PATH はビルド時に解決する。
    def build_launchd_plist(root)
      ruby_bindir = File.dirname(RbConfig.ruby)
      exec_path = File.join(root, "bin", "punch")
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
          <string>#{root}</string>
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
          <key>StandardOutPath</key>
          <string>#{root}/punch.log</string>
          <key>StandardErrorPath</key>
          <string>#{root}/punch.log</string>
        </dict>
        </plist>
      PLIST
    end

    # `punch plan` の計画を人間可読で出力する。
    def print_plan(day, cfg)
      puts "==== #{day[:date]} の打刻計画 ===="
      unless day[:target?]
        puts "対象日ではありません（#{day[:reason]}）。打刻しません。"
        return
      end

      if (leave = day[:leave_event])
        duration =
          if leave.all_day
            "終日"
          else
            format("%g時間", (leave.ends_at - leave.starts_at) / 3600.0)
          end
        puts "休暇検知: イベント『#{leave.title}』（#{duration}）→ この日は打刻しません"
        return
      end

      puts "出勤目標: #{day[:in_target].strftime('%H:%M:%S')}（所定 #{cfg.clock_in_time}#{cfg.clock_in_window.positive? ? "+0〜#{cfg.clock_in_window}分揺らぎ" : ''}）"
      puts

      plan = day[:out_plan]
      if day[:out_error]
        puts "カレンダー取得: 失敗（#{day[:out_error]}）→ 所定退勤時刻へフォールバック"
      elsif !cfg.calendar_enabled
        puts "カレンダー連動: OFF（config の calendar.enabled=false）→ 所定退勤時刻"
      elsif plan
        puts "取得イベント（当日・終了時刻ありのみ・終了昇順）:"
        if plan.considered_events.empty?
          puts "  (対象イベントなし)"
        else
          excluded_ids = plan.excluded_events.map(&:id)
          plan.considered_events.each do |ev|
            mark =
              if plan.adopted_event && ev.id == plan.adopted_event.id then "採用 ←"
              elsif excluded_ids.include?(ev.id) then "除外"
              else "対象外"
              end
            title = ev.title.nil? || ev.title.empty? ? "(タイトルなし)" : ev.title
            puts "  #{ev.starts_at&.strftime('%H:%M')}-#{ev.ends_at.strftime('%H:%M')} #{title}  [#{mark}]"
          end
        end
        puts
        if plan.source == :calendar
          puts "採用イベント: #{plan.adopted_event.title || '(タイトルなし)'}（終了 #{plan.adopted_event.ends_at.strftime('%H:%M')}）"
          puts "フォールバック: #{plan.fallback_reason}" if plan.fallback_reason
        else
          puts "採用イベントなし → 所定退勤時刻（理由: #{plan.fallback_reason}）"
        end
      end

      puts
      out_window = cfg.clock_out_window.positive? ? "+0〜#{cfg.clock_out_window}分揺らぎ" : ""
      puts "退勤目標: #{day[:out_target].strftime('%H:%M:%S')}#{out_window.empty? ? '' : "（#{out_window}）"}"
    end

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
