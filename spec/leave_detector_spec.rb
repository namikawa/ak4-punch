# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::LeaveDetector do
  subject(:detector) { described_class.new(keywords: %w[休暇 有給 休み], min_duration_hours: 4) }

  def t(hhmm)
    h, m = hhmm.split(":").map(&:to_i)
    Time.new(2026, 7, 13, h, m, 0, "+09:00")
  end

  def ev(title:, all_day: false, starts_at: nil, ends_at: nil)
    Ak4Punch::CalendarClient::Event.new(
      id: "x", title: title, starts_at: starts_at, ends_at: ends_at, location: nil, all_day: all_day,
    )
  end

  it "終日の休暇イベントは無条件で該当（時刻情報が無くてもよい）" do
    leave = detector.detect([ev(title: "夏季休暇", all_day: true)])
    expect(leave).not_to be_nil
    expect(leave.title).to eq "夏季休暇"
  end

  it "タイトルは部分一致で判定する" do
    expect(detector.detect([ev(title: "午後から有給取得", all_day: true)])).not_to be_nil
  end

  it "キーワード不一致は非該当" do
    expect(detector.detect([ev(title: "実装レビュー", all_day: true)])).to be_nil
  end

  it "4時間ちょうどの時間指定イベントは該当" do
    leave = detector.detect([ev(title: "午前休み", starts_at: t("09:00"), ends_at: t("13:00"))])
    expect(leave).not_to be_nil
  end

  it "3時間59分は非該当（短時間の中抜けを誤検知しない）" do
    events = [ev(title: "通院休み", starts_at: t("09:00"), ends_at: Time.new(2026, 7, 13, 12, 59, 0, "+09:00"))]
    expect(detector.detect(events)).to be_nil
  end

  it "starts_at が nil の時間指定イベントは非該当（長さを判定できない）" do
    expect(detector.detect([ev(title: "休暇", starts_at: nil, ends_at: t("18:00"))])).to be_nil
  end

  it "ends_at が nil の時間指定イベントは非該当" do
    expect(detector.detect([ev(title: "休暇", starts_at: t("09:00"), ends_at: nil)])).to be_nil
  end

  it "title が nil のイベントは非該当" do
    expect(detector.detect([ev(title: nil, all_day: true)])).to be_nil
  end

  it "複数イベントの中から休暇イベントを見つける（位置は問わない）" do
    events = [
      ev(title: "朝会", starts_at: t("10:00"), ends_at: t("10:30")),
      ev(title: "年次休暇", all_day: true),
      ev(title: "夕会", starts_at: t("17:00"), ends_at: t("17:30")),
    ]
    expect(detector.detect(events)&.title).to eq "年次休暇"
  end

  it "イベントなしは非該当" do
    expect(detector.detect([])).to be_nil
  end
end
