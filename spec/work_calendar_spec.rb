# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::WorkCalendar do
  subject(:calendar) do
    described_class.new(
      exclude_dates: [Date.new(2026, 7, 10)],   # 金曜だが除外
      extra_workdays: [Date.new(2026, 7, 11)],  # 土曜だが出勤
    )
  end

  it "平日は対象" do
    expect(calendar.target?(Date.new(2026, 7, 8))).to be true # 水曜
    expect(calendar.reason(Date.new(2026, 7, 8))).to be_nil
  end

  it "週末は非対象" do
    expect(calendar.target?(Date.new(2026, 7, 4))).to be false # 土曜
    expect(calendar.reason(Date.new(2026, 7, 5))).to eq "週末"  # 日曜
  end

  it "日本の祝日は非対象" do
    expect(calendar.target?(Date.new(2026, 1, 1))).to be false  # 元日(木)
    expect(calendar.reason(Date.new(2026, 1, 1))).to eq "祝日"
    expect(calendar.target?(Date.new(2026, 5, 5))).to be false  # こどもの日
  end

  it "除外日は非対象" do
    expect(calendar.reason(Date.new(2026, 7, 10))).to eq "除外日"
  end

  it "追加出勤日は最優先で対象" do
    expect(calendar.target?(Date.new(2026, 7, 11))).to be true
  end
end
