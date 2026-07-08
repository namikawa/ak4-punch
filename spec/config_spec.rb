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
end
