# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::ClockOutPlanner do
  subject(:planner) { described_class.new(exclude_keywords: %w[会食 懇親会]) }

  let(:date) { Date.new(2026, 7, 10) }
  let(:default_clock_out) { t("18:00") }

  # 当日(2026-07-10)の HH:MM を JST の Time にする
  def t(hhmm, day: 10)
    h, m = hhmm.split(":").map(&:to_i)
    Time.new(2026, 7, day, h, m, 0, "+09:00")
  end

  def event(title:, ends_at:, starts_at: nil, all_day: false, id: nil)
    Ak4Punch::CalendarClient::Event.new(
      id: id || "e#{ends_at&.to_i}#{title}",
      title: title, starts_at: starts_at, ends_at: ends_at, location: nil, all_day: all_day,
    )
  end

  it "通常: 末尾の業務イベントの終了時刻を採用（所定より遅い）" do
    events = [
      event(title: "朝会", ends_at: t("10:00")),
      event(title: "打合せ", ends_at: t("19:30")),
    ]
    plan = planner.plan(events: events, date: date, default_clock_out: default_clock_out)

    expect(plan.source).to eq :calendar
    expect(plan.target_at).to eq t("19:30")
    expect(plan.adopted_event.title).to eq "打合せ"
    expect(plan.excluded_events).to be_empty
  end

  it "末尾会食除外: 直前の業務イベントの終了時刻を採用" do
    events = [
      event(title: "定例MTG", ends_at: t("18:30")),
      event(title: "部の会食", ends_at: t("21:00")),
    ]
    plan = planner.plan(events: events, date: date, default_clock_out: default_clock_out)

    expect(plan.target_at).to eq t("18:30")
    expect(plan.adopted_event.title).to eq "定例MTG"
    expect(plan.excluded_events.map(&:title)).to eq ["部の会食"]
  end

  it "連続除外: 末尾から複数の除外イベントを飛ばして採用" do
    events = [
      event(title: "設計レビュー", ends_at: t("17:00")),
      event(title: "懇親会準備", ends_at: t("18:30")),
      event(title: "会食", ends_at: t("21:00")),
    ]
    plan = planner.plan(events: events, date: date, default_clock_out: default_clock_out)

    expect(plan.target_at).to eq default_clock_out # 17:00 < 18:00 なので所定
    expect(plan.adopted_event.title).to eq "設計レビュー"
    expect(plan.excluded_events.map(&:title)).to eq %w[会食 懇親会準備]
  end

  it "全除外: 候補なし → 所定退勤時刻へフォールバック" do
    events = [
      event(title: "会食", ends_at: t("20:00")),
      event(title: "懇親会", ends_at: t("22:00")),
    ]
    plan = planner.plan(events: events, date: date, default_clock_out: default_clock_out)

    expect(plan.source).to eq :default
    expect(plan.target_at).to eq default_clock_out
    expect(plan.adopted_event).to be_nil
    expect(plan.fallback_reason).to include "除外キーワード"
  end

  it "イベントなし: 所定退勤時刻" do
    plan = planner.plan(events: [], date: date, default_clock_out: default_clock_out)
    expect(plan.source).to eq :default
    expect(plan.target_at).to eq default_clock_out
    expect(plan.fallback_reason).to include "業務イベントがありません"
  end

  it "終日イベントは対象外" do
    events = [
      event(title: "全休", ends_at: t("23:59"), all_day: true),
      event(title: "実装", ends_at: t("19:00")),
    ]
    plan = planner.plan(events: events, date: date, default_clock_out: default_clock_out)
    expect(plan.adopted_event.title).to eq "実装"
    expect(plan.considered_events.map(&:title)).to eq ["実装"]
  end

  it "ends_at が null のイベントは対象外" do
    events = [
      event(title: "終了未定", ends_at: nil),
      event(title: "レビュー", ends_at: t("18:45")),
    ]
    plan = planner.plan(events: events, date: date, default_clock_out: default_clock_out)
    expect(plan.adopted_event.title).to eq "レビュー"
    expect(plan.target_at).to eq t("18:45")
  end

  it "日跨ぎ（ends_at が翌日）のイベントは対象外" do
    events = [
      event(title: "夜間バッチ監視", ends_at: t("02:00", day: 11)), # 翌日終了
      event(title: "実装", ends_at: t("18:20")),
    ]
    plan = planner.plan(events: events, date: date, default_clock_out: default_clock_out)
    expect(plan.considered_events.map(&:title)).to eq ["実装"]
    expect(plan.target_at).to eq t("18:20")
  end

  it "title が nil のイベントは除外対象にしない（業務扱い）" do
    events = [event(title: nil, ends_at: t("19:15"))]
    plan = planner.plan(events: events, date: date, default_clock_out: default_clock_out)
    expect(plan.source).to eq :calendar
    expect(plan.target_at).to eq t("19:15")
    expect(plan.adopted_event.title).to be_nil
  end

  describe "max則" do
    it "採用イベントが所定より早い → 所定退勤時刻を採用" do
      events = [event(title: "早上がり枠", ends_at: t("17:30"))]
      plan = planner.plan(events: events, date: date, default_clock_out: default_clock_out)
      expect(plan.source).to eq :calendar
      expect(plan.target_at).to eq default_clock_out
      expect(plan.fallback_reason).to include "所定退勤時刻より早い"
    end

    it "採用イベントが所定より遅い → イベント終了時刻を採用" do
      events = [event(title: "長引いた会議", ends_at: t("20:10"))]
      plan = planner.plan(events: events, date: date, default_clock_out: default_clock_out)
      expect(plan.target_at).to eq t("20:10")
      expect(plan.fallback_reason).to be_nil
    end
  end
end
