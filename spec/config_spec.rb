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

  describe "カレンダー連動・デーモン設定" do
    it "既定値を持つ（未設定時）" do
      cfg = described_class.new(data: { "company_id" => "x" }, root: Dir.pwd)
      expect(cfg.calendar_enabled).to be false
      expect(cfg.calendar_exclude_keywords).to eq described_class::DEFAULT_EXCLUDE_KEYWORDS
      expect(cfg.calendar_refresh_interval_minutes).to eq 15
      expect(cfg.daemon_tick_seconds).to eq 30
      expect(cfg.daemon_wake_lead_minutes).to eq 1
      expect(cfg.daemon_manage_wake).to be true
      expect(cfg.daemon_late_grace_minutes).to eq 10
      expect(cfg.sukesan_base_url).to eq "http://127.0.0.1:3000"
    end

    it "config の値で上書きできる" do
      cfg = described_class.new(
        data: {
          "company_id" => "x",
          "calendar" => {
            "enabled" => true,
            "exclude_keywords" => %w[飲み会 打ち上げ],
            "refresh_interval_minutes" => 5,
          },
          "daemon" => {
            "tick_seconds" => 60, "wake_lead_minutes" => 2,
            "manage_wake" => false, "late_grace_minutes" => 20,
          },
        },
        root: Dir.pwd,
      )
      expect(cfg.calendar_enabled).to be true
      expect(cfg.calendar_exclude_keywords).to eq %w[飲み会 打ち上げ]
      expect(cfg.calendar_refresh_interval_minutes).to eq 5
      expect(cfg.daemon_tick_seconds).to eq 60
      expect(cfg.daemon_wake_lead_minutes).to eq 2
      expect(cfg.daemon_manage_wake).to be false
      expect(cfg.daemon_late_grace_minutes).to eq 20
    end

    it "不正な数値（0以下）は既定値へフォールバック" do
      cfg = described_class.new(
        data: {
          "company_id" => "x",
          "calendar" => { "refresh_interval_minutes" => 0 },
          "daemon" => { "tick_seconds" => -1, "late_grace_minutes" => 0 },
        },
        root: Dir.pwd,
      )
      expect(cfg.calendar_refresh_interval_minutes).to eq 15
      expect(cfg.daemon_tick_seconds).to eq 30
      expect(cfg.daemon_late_grace_minutes).to eq 10
    end

    it "exclude_keywords を空配列にすると除外なしにできる" do
      cfg = described_class.new(
        data: { "company_id" => "x", "calendar" => { "exclude_keywords" => [] } },
        root: Dir.pwd,
      )
      expect(cfg.calendar_exclude_keywords).to eq []
    end
  end
end
