# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::Config do
  it "既定値を持つ" do
    cfg = described_class.new(data: { "company_id" => "soldout" }, root: Dir.pwd)
    expect(cfg.company_id).to eq "soldout"
    expect(cfg.clock_in_time).to eq "09:30"
    expect(cfg.clock_out_time).to eq "18:00"
    expect(cfg.weekdays_only).to be true
    expect(cfg.skip_japanese_holidays).to be true
    expect(cfg.check_existing).to be true
    expect(cfg.base_url).to eq "https://atnd.ak4.jp/api/cooperation"
  end

  it "schedule の日付を Date に変換する" do
    cfg = described_class.new(
      data: {
        "company_id" => "x",
        "schedule" => { "exclude_dates" => ["2026-12-29"], "extra_workdays" => ["2026-07-11"] },
      },
      root: Dir.pwd,
    )
    expect(cfg.exclude_dates).to eq [Date.new(2026, 12, 29)]
    expect(cfg.extra_workdays).to eq [Date.new(2026, 7, 11)]
  end

  it "company_id 未設定ならエラー" do
    expect { described_class.new(data: {}, root: Dir.pwd) }.to raise_error(Ak4Punch::Config::Error)
  end

  describe "所定時刻(work.clock_in / clock_out)の検証" do
    def cfg_with(work)
      described_class.new(data: { "company_id" => "x", "work" => work }, root: Dir.pwd)
    end

    it "HH:MM 形式（0埋めなし・境界値）を受理する" do
      cfg = cfg_with("clock_in" => "9:30", "clock_out" => "23:59")
      expect(cfg.clock_in_time).to eq "9:30"
      expect(cfg.clock_out_time).to eq "23:59"
      expect(cfg_with("clock_in" => "00:00", "clock_out" => "09:30").clock_in_time).to eq "00:00"
    end

    it "既定値（未設定時）も検証を通る" do
      cfg = described_class.new(data: { "company_id" => "x" }, root: Dir.pwd)
      expect(cfg.clock_in_time).to eq "09:30"
      expect(cfg.clock_out_time).to eq "18:00"
    end

    it "時が範囲外ならエラー（どのキーがどの値で不正か分かる）" do
      expect { cfg_with("clock_in" => "25:00") }
        .to raise_error(Ak4Punch::Config::Error, /work\.clock_in の時刻指定が不正です.*25:00/)
    end

    it "分が範囲外ならエラー" do
      expect { cfg_with("clock_out" => "12:60") }
        .to raise_error(Ak4Punch::Config::Error, /work\.clock_out の時刻指定が不正です.*12:60/)
    end

    it "時刻でない文字列ならエラー（00:00 として黙って受理しない）" do
      expect { cfg_with("clock_in" => "oops") }
        .to raise_error(Ak4Punch::Config::Error, /work\.clock_in の時刻指定が不正です.*oops/)
      expect { cfg_with("clock_out" => "9:xx") }
        .to raise_error(Ak4Punch::Config::Error, /work\.clock_out の時刻指定が不正です.*9:xx/)
    end

    it "数値（YAML で引用符を付け忘れた場合）もエラー" do
      expect { cfg_with("clock_in" => 930) }
        .to raise_error(Ak4Punch::Config::Error, /work\.clock_in の時刻指定が不正です.*930/)
    end
  end

  describe "ランダム打刻ウィンドウ" do
    it "既定は 0（指定時刻ちょうど）" do
      cfg = described_class.new(data: { "company_id" => "x" }, root: Dir.pwd)
      expect(cfg.clock_in_window).to eq 0
      expect(cfg.clock_out_window).to eq 0
    end

    it "random_window_minutes は in/out 共通の既定になる" do
      cfg = described_class.new(
        data: { "company_id" => "x", "work" => { "random_window_minutes" => 5 } },
        root: Dir.pwd,
      )
      expect(cfg.clock_in_window).to eq 5
      expect(cfg.clock_out_window).to eq 5
    end

    it "clock_in_window / clock_out_window で個別上書きできる" do
      cfg = described_class.new(
        data: {
          "company_id" => "x",
          "work" => { "random_window_minutes" => 5, "clock_in_window" => 0, "clock_out_window" => 10 },
        },
        root: Dir.pwd,
      )
      expect(cfg.clock_in_window).to eq 0
      expect(cfg.clock_out_window).to eq 10
    end

    it "上限(30)超過は 30、負値は 0 に丸める" do
      cfg = described_class.new(
        data: { "company_id" => "x", "work" => { "clock_in_window" => 99, "clock_out_window" => -5 } },
        root: Dir.pwd,
      )
      expect(cfg.clock_in_window).to eq 30
      expect(cfg.clock_out_window).to eq 0
    end
  end

  describe "所定時刻とウィンドウの組み合わせの検証" do
    def cfg_with(work)
      described_class.new(data: { "company_id" => "x", "work" => work }, root: Dir.pwd)
    end

    it "出勤の打刻締切が退勤時刻以降になる設定はエラー" do
      # 実測: clock_in 17:50 / clock_out 18:00 / window 30 で出勤目標 18:14・退勤目標 18:10 になり、
      # 先に来た退勤が未出勤で冪等スキップされ、出勤だけが記録された。
      expect { cfg_with("clock_in" => "17:50", "clock_out" => "18:00", "random_window_minutes" => 30) }
        .to raise_error(Ak4Punch::Config::Error, /出勤の打刻締切.*18:20.*work\.clock_out\(18:00\) 以降/)
    end

    it "締切がちょうど退勤時刻と同じでもエラー（退勤が先に来る余地を残さない）" do
      expect { cfg_with("clock_in" => "17:30", "clock_out" => "18:00", "clock_in_window" => 30) }
        .to raise_error(Ak4Punch::Config::Error, /出勤の打刻締切.*18:00.*以降/)
    end

    it "締切が退勤時刻の1分前（境界）なら受理する" do
      cfg = cfg_with("clock_in" => "17:29", "clock_out" => "18:00", "clock_in_window" => 30)
      expect(cfg.clock_in_window).to eq 30
      expect(cfg.clock_out_time).to eq "18:00"
    end

    it "退勤の打刻目標が翌日になる設定はエラー（日付が変わると計画が破棄され未打刻になる）" do
      expect { cfg_with("clock_out" => "23:59", "clock_out_window" => 5) }
        .to raise_error(Ak4Punch::Config::Error, /退勤の打刻目標が翌日になります.*23:59.*翌日 00:04/)
    end

    it "出勤の打刻締切が翌日になる設定もエラー" do
      expect { cfg_with("clock_in" => "23:50", "clock_out" => "23:59", "clock_in_window" => 20) }
        .to raise_error(Ak4Punch::Config::Error, /出勤の打刻締切が翌日になります.*23:50.*翌日 00:10/)
    end

    it "退勤の打刻目標がちょうど 23:59（境界）なら受理する" do
      cfg = cfg_with("clock_out" => "23:58", "clock_out_window" => 1)
      expect(cfg.clock_out_window).to eq 1
    end

    it "既定値（09:30/18:00・ウィンドウ0）は受理する" do
      cfg = described_class.new(data: { "company_id" => "x" }, root: Dir.pwd)
      expect(cfg.clock_in_time).to eq "09:30"
      expect(cfg.clock_out_time).to eq "18:00"
    end
  end

  describe "token.refresh_threshold_days の検証" do
    def cfg_with_threshold(value)
      described_class.new(
        data: { "company_id" => "x", "token" => { "refresh_threshold_days" => value } },
        root: Dir.pwd,
      )
    end

    it "既定は 7 日" do
      cfg = described_class.new(data: { "company_id" => "x" }, root: Dir.pwd)
      expect(cfg.token_refresh_threshold_days).to eq 7
    end

    it "整数・数値文字列を受理する" do
      expect(cfg_with_threshold(3).token_refresh_threshold_days).to eq 3
      expect(cfg_with_threshold("3").token_refresh_threshold_days).to eq 3
    end

    it "境界値 0 と 31 を受理する（0 = 期限切れまで再発行しない）" do
      expect(cfg_with_threshold(0).token_refresh_threshold_days).to eq 0
      expect(cfg_with_threshold(31).token_refresh_threshold_days).to eq 31
    end

    it "値なし（YAML で キー: のみ → nil）はエラー（既定値へ黙って落とさない）" do
      # nil のままだと TokenStore#needs_refresh? の乗算で NoMethodError になり、
      # 打刻の直前に毎 tick 失敗して grace 超過で未打刻になる。
      expect { cfg_with_threshold(nil) }
        .to raise_error(Ak4Punch::Config::Error, /token\.refresh_threshold_days は 0〜31 の整数で.*nil/)
    end

    it "小数はエラー（Integer() の切り捨てで黙って通さない）" do
      expect { cfg_with_threshold(7.9) }
        .to raise_error(Ak4Punch::Config::Error, /token\.refresh_threshold_days は 0〜31 の整数で.*7\.9/)
      expect { cfg_with_threshold(31.9) }
        .to raise_error(Ak4Punch::Config::Error, /token\.refresh_threshold_days.*31\.9/)
    end

    it "16進表記の文字列はエラー（基数10で解釈する）" do
      expect { cfg_with_threshold("0x1f") }
        .to raise_error(Ak4Punch::Config::Error, /token\.refresh_threshold_days.*0x1f/)
    end

    it "整数化できない文字列はエラー" do
      expect { cfg_with_threshold("ななにち") }
        .to raise_error(Ak4Punch::Config::Error, /token\.refresh_threshold_days.*ななにち/)
    end

    it "範囲外（負値・32以上）はエラー" do
      expect { cfg_with_threshold(-1) }
        .to raise_error(Ak4Punch::Config::Error, /token\.refresh_threshold_days.*-1/)
      expect { cfg_with_threshold(32) }
        .to raise_error(Ak4Punch::Config::Error, /token\.refresh_threshold_days.*32/)
    end
  end

  describe "カレンダー連動・デーモン設定" do
    it "既定値を持つ（未設定時）" do
      cfg = described_class.new(data: { "company_id" => "x" }, root: Dir.pwd)
      expect(cfg.calendar_enabled).to be false
      expect(cfg.calendar_exclude_keywords).to eq described_class::DEFAULT_EXCLUDE_KEYWORDS
      expect(cfg.calendar_clock_in_exclude_keywords).to eq described_class::DEFAULT_CLOCK_IN_EXCLUDE_KEYWORDS
      expect(cfg.calendar_clock_in_exclude_keywords).to eq %w[移動 私用]
      expect(cfg.calendar_refresh_interval_minutes).to eq 15
      expect(cfg.calendar_refresh_failure_notify_threshold).to eq 3
      expect(cfg.daemon_tick_seconds).to eq 30
      expect(cfg.daemon_wake_lead_minutes).to eq 1
      expect(cfg.daemon_manage_wake).to be true
      expect(cfg.daemon_late_grace_minutes).to eq 10
      # 未設定なら従来動作（起床時刻・出勤アンカーの下限とも所定出勤時刻。
      # 下限が無くなるのではなく、所定より前に始まる予定がアンカーにならない＝出勤の連動が実質無効になる）
      expect(cfg.daemon_morning_wake_at).to be_nil
      expect(cfg.sukesan_base_url).to eq "http://127.0.0.1:3000"
    end

    it "config の値で上書きできる" do
      cfg = described_class.new(
        data: {
          "company_id" => "x",
          "calendar" => {
            "enabled" => true,
            "exclude_keywords" => %w[飲み会 打ち上げ],
            "clock_in_exclude_keywords" => %w[移動 通院],
            "refresh_interval_minutes" => 5,
            "refresh_failure_notify_threshold" => 6,
          },
          "daemon" => {
            "tick_seconds" => 60, "wake_lead_minutes" => 2,
            "manage_wake" => false, "late_grace_minutes" => 20,
            "morning_wake_at" => "07:45",
          },
        },
        root: Dir.pwd,
      )
      expect(cfg.calendar_enabled).to be true
      expect(cfg.calendar_exclude_keywords).to eq %w[飲み会 打ち上げ]
      expect(cfg.calendar_clock_in_exclude_keywords).to eq %w[移動 通院]
      expect(cfg.calendar_refresh_interval_minutes).to eq 5
      expect(cfg.calendar_refresh_failure_notify_threshold).to eq 6
      expect(cfg.daemon_tick_seconds).to eq 60
      expect(cfg.daemon_wake_lead_minutes).to eq 2
      expect(cfg.daemon_manage_wake).to be false
      expect(cfg.daemon_late_grace_minutes).to eq 20
      expect(cfg.daemon_morning_wake_at).to eq "07:45"
    end

    it "不正な数値（0以下）は既定値へフォールバック" do
      cfg = described_class.new(
        data: {
          "company_id" => "x",
          "calendar" => { "refresh_interval_minutes" => 0, "refresh_failure_notify_threshold" => 0 },
          "daemon" => { "tick_seconds" => -1, "late_grace_minutes" => 0 },
        },
        root: Dir.pwd,
      )
      expect(cfg.calendar_refresh_interval_minutes).to eq 15
      expect(cfg.calendar_refresh_failure_notify_threshold).to eq 3
      expect(cfg.daemon_tick_seconds).to eq 30
      expect(cfg.daemon_late_grace_minutes).to eq 10
    end

    it "refresh_failure_notify_threshold の負値・不正値も既定値(3)へフォールバック" do
      negative = described_class.new(
        data: { "company_id" => "x", "calendar" => { "refresh_failure_notify_threshold" => -2 } },
        root: Dir.pwd,
      )
      invalid = described_class.new(
        data: { "company_id" => "x", "calendar" => { "refresh_failure_notify_threshold" => "たくさん" } },
        root: Dir.pwd,
      )
      expect(negative.calendar_refresh_failure_notify_threshold).to eq 3
      expect(invalid.calendar_refresh_failure_notify_threshold).to eq 3
    end

    it "exclude_keywords を空配列にすると除外なしにできる" do
      cfg = described_class.new(
        data: { "company_id" => "x", "calendar" => { "exclude_keywords" => [] } },
        root: Dir.pwd,
      )
      expect(cfg.calendar_exclude_keywords).to eq []
    end

    it "clock_in_exclude_keywords を空配列にすると出勤側の除外なしにできる" do
      cfg = described_class.new(
        data: { "company_id" => "x", "calendar" => { "clock_in_exclude_keywords" => [] } },
        root: Dir.pwd,
      )
      expect(cfg.calendar_clock_in_exclude_keywords).to eq []
      # 退勤側の既定には影響しない（独立した設定）
      expect(cfg.calendar_exclude_keywords).to eq described_class::DEFAULT_EXCLUDE_KEYWORDS
    end

    describe "daemon.morning_wake_at の検証" do
      def cfg_with_wake(value)
        described_class.new(
          data: { "company_id" => "x", "daemon" => { "morning_wake_at" => value } },
          root: Dir.pwd,
        )
      end

      it "HH:MM 形式を受理する" do
        expect(cfg_with_wake("7:05").daemon_morning_wake_at).to eq "7:05"
        expect(cfg_with_wake("07:45").daemon_morning_wake_at).to eq "07:45"
      end

      it "時刻でない文字列はエラー（どのキーがどの値で不正か分かる）" do
        expect { cfg_with_wake("あさ") }
          .to raise_error(Ak4Punch::Config::Error, /daemon\.morning_wake_at の時刻指定が不正です.*あさ/)
      end

      it "範囲外・数値（YAML で引用符を付け忘れた場合）もエラー" do
        expect { cfg_with_wake("24:00") }
          .to raise_error(Ak4Punch::Config::Error, /daemon\.morning_wake_at の時刻指定が不正です.*24:00/)
        expect { cfg_with_wake(745) }
          .to raise_error(Ak4Punch::Config::Error, /daemon\.morning_wake_at の時刻指定が不正です.*745/)
      end

      it "未設定（nil）はエラーにしない" do
        expect(cfg_with_wake(nil).daemon_morning_wake_at).to be_nil
      end
    end
  end

  describe "休暇イベントのキーワード設定" do
    it "既定値を持つ（未設定時）" do
      cfg = described_class.new(data: { "company_id" => "x" }, root: Dir.pwd)
      expect(cfg.calendar_leave_keywords).to eq %w[休み 休暇]
    end

    it "config の値で上書きできる" do
      cfg = described_class.new(
        data: { "company_id" => "x", "calendar" => { "leave_keywords" => %w[休暇 PTO] } },
        root: Dir.pwd,
      )
      expect(cfg.calendar_leave_keywords).to eq %w[休暇 PTO]
    end

    it "leave_keywords を空配列にすると休暇の判定なしにできる" do
      cfg = described_class.new(
        data: { "company_id" => "x", "calendar" => { "leave_keywords" => [] } },
        root: Dir.pwd,
      )
      expect(cfg.calendar_leave_keywords).to eq []
    end
  end

  describe "Slack 通知設定" do
    it "slack_webhook_url は環境変数(SLACK_WEBHOOK_URL)から読む" do
      ENV["SLACK_WEBHOOK_URL"] = "https://hooks.slack.com/services/T000/B000/XXXX"
      cfg = described_class.new(data: { "company_id" => "x" }, root: Dir.pwd)
      expect(cfg.slack_webhook_url).to eq "https://hooks.slack.com/services/T000/B000/XXXX"
    ensure
      ENV.delete("SLACK_WEBHOOK_URL")
    end

    it "未設定なら nil（通知は無効）" do
      cfg = described_class.new(data: { "company_id" => "x" }, root: Dir.pwd)
      expect(cfg.slack_webhook_url).to be_nil
    end

    it "slack_mention は環境変数(SLACK_MENTION)から読む（未設定なら nil）" do
      ENV["SLACK_MENTION"] = "<@U04XXXXXX>"
      cfg = described_class.new(data: { "company_id" => "x" }, root: Dir.pwd)
      expect(cfg.slack_mention).to eq "<@U04XXXXXX>"
    ensure
      ENV.delete("SLACK_MENTION")
    end
  end
end
