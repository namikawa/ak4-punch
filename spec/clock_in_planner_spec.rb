# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::ClockInPlanner do
  subject(:planner) { described_class.new(exclude_keywords: %w[移動 私用]) }

  let(:date) { Date.new(2026, 7, 10) }
  let(:default_deadline) { t("09:30") } # 所定の出勤締切（所定出勤時刻 + ウィンドウ）

  # 当日(2026-07-10)の HH:MM を JST の Time にする
  def t(hhmm, day: 10)
    h, m = hhmm.split(":").map(&:to_i)
    Time.new(2026, 7, day, h, m, 0, "+09:00")
  end

  def event(title:, starts_at:, ends_at: nil, all_day: false, id: nil)
    Ak4Punch::CalendarClient::Event.new(
      id: id || "e#{starts_at&.to_i}#{title}",
      title: title, starts_at: starts_at, ends_at: ends_at, location: nil, all_day: all_day,
    )
  end

  it "通常: 最初の業務イベントの開始時刻を締切に採用（所定より早い）" do
    events = [
      event(title: "定例MTG", starts_at: t("09:00")),
      event(title: "実装", starts_at: t("13:00")),
    ]
    plan = planner.plan(events: events, date: date, default_deadline: default_deadline)

    expect(plan.source).to eq :calendar
    expect(plan.deadline_at).to eq t("09:00")
    expect(plan.adopted_event.title).to eq "定例MTG"
    expect(plan.excluded_events).to be_empty
    expect(plan.fallback_reason).to be_nil
  end

  it "先頭除外: 除外キーワードのイベントを飛ばして次を採用" do
    events = [
      event(title: "移動", starts_at: t("08:00")),
      event(title: "朝会", starts_at: t("09:15")),
    ]
    plan = planner.plan(events: events, date: date, default_deadline: default_deadline)

    expect(plan.deadline_at).to eq t("09:15")
    expect(plan.adopted_event.title).to eq "朝会"
    expect(plan.excluded_events.map(&:title)).to eq ["移動"]
  end

  it "連続除外: 先頭から複数の除外イベントを飛ばして採用（移動→私用→会議）" do
    events = [
      event(title: "移動", starts_at: t("08:00")),
      event(title: "私用", starts_at: t("08:30")),
      event(title: "定例会議", starts_at: t("09:00")),
    ]
    plan = planner.plan(events: events, date: date, default_deadline: default_deadline)

    expect(plan.deadline_at).to eq t("09:00")
    expect(plan.adopted_event.title).to eq "定例会議"
    expect(plan.excluded_events.map(&:title)).to eq %w[移動 私用]
  end

  it "全除外: 候補なし → 所定の出勤締切へフォールバック" do
    events = [
      event(title: "移動", starts_at: t("08:00")),
      event(title: "私用の予定", starts_at: t("08:30")),
    ]
    plan = planner.plan(events: events, date: date, default_deadline: default_deadline)

    expect(plan.source).to eq :default
    expect(plan.deadline_at).to eq default_deadline
    expect(plan.adopted_event).to be_nil
    expect(plan.fallback_reason).to include "除外キーワード"
  end

  it "イベントなし: 所定の出勤締切" do
    plan = planner.plan(events: [], date: date, default_deadline: default_deadline)
    expect(plan.source).to eq :default
    expect(plan.deadline_at).to eq default_deadline
    expect(plan.fallback_reason).to include "業務イベントがありません"
  end

  it "終日イベントは対象外" do
    events = [
      event(title: "全社イベント", starts_at: t("00:00"), all_day: true),
      event(title: "打合せ", starts_at: t("09:00")),
    ]
    plan = planner.plan(events: events, date: date, default_deadline: default_deadline)
    expect(plan.adopted_event.title).to eq "打合せ"
    expect(plan.considered_events.map(&:title)).to eq ["打合せ"]
  end

  it "starts_at が null のイベントは対象外" do
    events = [
      event(title: "開始未定", starts_at: nil),
      event(title: "レビュー", starts_at: t("09:10")),
    ]
    plan = planner.plan(events: events, date: date, default_deadline: default_deadline)
    expect(plan.adopted_event.title).to eq "レビュー"
    expect(plan.deadline_at).to eq t("09:10")
  end

  it "別日（前日から続く日跨ぎ）のイベントは対象外" do
    events = [
      event(title: "夜間バッチ監視", starts_at: t("22:00", day: 9)), # 前日開始
      event(title: "打合せ", starts_at: t("09:20")),
    ]
    plan = planner.plan(events: events, date: date, default_deadline: default_deadline)
    expect(plan.considered_events.map(&:title)).to eq ["打合せ"]
    expect(plan.deadline_at).to eq t("09:20")
  end

  it "title が nil のイベントは除外対象にしない（業務扱い）" do
    events = [event(title: nil, starts_at: t("08:45"))]
    plan = planner.plan(events: events, date: date, default_deadline: default_deadline)
    expect(plan.source).to eq :calendar
    expect(plan.deadline_at).to eq t("08:45")
    expect(plan.adopted_event.title).to be_nil
  end

  describe "earliest_at（出勤目標の下限）" do
    it "下限より前に始まるイベントは採用せず too_early_events に入れる" do
      events = [
        event(title: "海外定例", starts_at: t("06:00")),
        event(title: "朝会", starts_at: t("09:05")),
      ]
      plan = planner.plan(events: events, date: date, default_deadline: default_deadline,
                          earliest_at: t("07:45"))

      expect(plan.adopted_event.title).to eq "朝会"
      expect(plan.deadline_at).to eq t("09:05")
      expect(plan.too_early_events.map(&:title)).to eq ["海外定例"]
      expect(plan.considered_events.map(&:title)).to eq ["朝会"]
    end

    it "下限より前のイベントしかなければ所定の出勤締切へフォールバック" do
      events = [event(title: "深夜対応", starts_at: t("00:30"))]
      plan = planner.plan(events: events, date: date, default_deadline: default_deadline,
                          earliest_at: t("07:45"))

      expect(plan.source).to eq :default
      expect(plan.deadline_at).to eq default_deadline
      expect(plan.too_early_events.map(&:title)).to eq ["深夜対応"]
      expect(plan.fallback_reason).to include "全て下限時刻（07:45）より前"
    end

    it "下限ちょうどに始まるイベントは採用する" do
      events = [event(title: "早朝レビュー", starts_at: t("07:45"))]
      plan = planner.plan(events: events, date: date, default_deadline: default_deadline,
                          earliest_at: t("07:45"))

      expect(plan.deadline_at).to eq t("07:45")
      expect(plan.too_early_events).to be_empty
    end

    it "earliest_at なし（nil）なら下限なしで早朝イベントも採用する" do
      events = [event(title: "海外定例", starts_at: t("06:00"))]
      plan = planner.plan(events: events, date: date, default_deadline: default_deadline)

      expect(plan.deadline_at).to eq t("06:00")
      expect(plan.too_early_events).to be_empty
    end
  end

  describe "min則" do
    it "採用イベントが所定の締切より遅い → 所定の締切を採用" do
      events = [event(title: "午後の打合せ", starts_at: t("14:00"))]
      plan = planner.plan(events: events, date: date, default_deadline: default_deadline)

      expect(plan.source).to eq :calendar
      expect(plan.deadline_at).to eq default_deadline
      expect(plan.fallback_reason).to include "所定の出勤締切より遅い"
    end

    it "採用イベントが所定の締切より早い → イベント開始時刻を採用" do
      events = [event(title: "朝一MTG", starts_at: t("08:30"))]
      plan = planner.plan(events: events, date: date, default_deadline: default_deadline)

      expect(plan.deadline_at).to eq t("08:30")
      expect(plan.fallback_reason).to be_nil
    end
  end
end
