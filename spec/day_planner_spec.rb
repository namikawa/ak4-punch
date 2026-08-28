# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::DayPlanner do
  # 当日(2026-07-10 金曜)の HH:MM:SS を JST の Time にする
  def t(hhmm, sec = 0, day: 10)
    h, m = hhmm.split(":").map(&:to_i)
    Time.new(2026, 7, day, h, m, sec, "+09:00")
  end

  let(:date) { Date.new(2026, 7, 10) }

  # 揺らぎ0で目標時刻が所定/イベント終了ちょうどになるよう window=0 の設定を使う
  let(:config) do
    Ak4Punch::Config.new(
      data: {
        "company_id" => "x",
        "work" => { "clock_in" => "09:30", "clock_out" => "18:00" },
        "calendar" => { "enabled" => true, "exclude_keywords" => ["会食"], "refresh_interval_minutes" => 15 },
        "daemon" => { "tick_seconds" => 30, "late_grace_minutes" => 10, "manage_wake" => true, "wake_lead_minutes" => 1 },
      },
      root: Dir.pwd,
    )
  end

  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }

  subject(:planner) { described_class.new(config: config, logger: logger) }

  def event(title:, ends_at:, starts_at: nil, all_day: false, id: nil)
    Ak4Punch::CalendarClient::Event.new(
      id: id || "e#{title}", title: title, starts_at: starts_at, ends_at: ends_at,
      all_day: all_day,
    )
  end

  # 「休暇」イベントは『その時間帯は勤務しない』の意味。打刻の基準時刻がその時間帯に
  # 入っていたら休暇の外へ押し出す（出勤＝終了へ後ろ倒し／退勤＝開始へ前倒し）。
  # 所定は 出勤締切 09:30（clock_in 09:30 + window 0）/ 退勤基準 18:00。
  describe "休暇イベントの時間帯を打刻計画に反映する" do
    # [出勤締切, 退勤基準, 全休か] を返す
    def plan_for(events)
      day = planner.call(date: date, events: events)
      [day.clock_in.deadline, day.clock_out.base, day.full_leave?]
    end

    def span(title, from, to)
      event(title: title, starts_at: t(from), ends_at: t(to))
    end

    it "休暇なし → 所定どおり" do
      expect(plan_for([])).to eq [t("09:30"), t("18:00"), false]
    end

    it "休暇 12:00-19:00（午後休）→ 退勤は休暇の開始へ前倒し" do
      expect(plan_for([span("休暇", "12:00", "19:00")])).to eq [t("09:30"), t("12:00"), false]
    end

    it "休暇 15:00-18:00 → 退勤基準（所定18:00）は休暇の終端に一致するので前倒しする" do
      expect(plan_for([span("休暇", "15:00", "18:00")])).to eq [t("09:30"), t("15:00"), false]
    end

    it "休暇 15:00-18:30 → 退勤は休暇の開始へ前倒し" do
      expect(plan_for([span("休暇", "15:00", "18:30")])).to eq [t("09:30"), t("15:00"), false]
    end

    it "休暇 15:00-19:00 ＋ 会議 19:00-20:00 → 退勤は会議の終了（中抜け扱い・押し出しなし）" do
      events = [span("休暇", "15:00", "19:00"), span("会議", "19:00", "20:00")]
      expect(plan_for(events)).to eq [t("09:30"), t("20:00"), false]
    end

    it "休暇 15:00-17:00（中抜け）→ 所定退勤のまま" do
      expect(plan_for([span("休暇", "15:00", "17:00")])).to eq [t("09:30"), t("18:00"), false]
    end

    it "休暇 09:00-13:00（午前休）→ 出勤締切は休暇の終了へ後ろ倒し" do
      expect(plan_for([span("休暇", "09:00", "13:00")])).to eq [t("13:00"), t("18:00"), false]
    end

    it "休暇 09:00-18:00 → 出勤締切 >= 退勤基準 になり全休" do
      expect(plan_for([span("休暇", "09:00", "18:00")]).last).to be true
    end

    it "終日休暇 → 全休（00:00〜翌00:00 の休暇として押し出された帰結）" do
      expect(plan_for([event(title: "夏季休暇", ends_at: nil, all_day: true)]).last).to be true
    end

    it "「昼休み」12:00-13:00 は休暇だが打刻には影響しない" do
      expect(plan_for([span("昼休み", "12:00", "13:00")])).to eq [t("09:30"), t("18:00"), false]
    end

    it "午前休 09:00-12:00 ＋ 午後休 13:00-19:00 → 出勤12:00 / 退勤13:00" do
      events = [span("午前休み", "09:00", "12:00"), span("午後休み", "13:00", "19:00")]
      expect(plan_for(events)).to eq [t("12:00"), t("13:00"), false]
    end

    it "業務イベントと休暇が混在する日（午後休）も業務イベント側は従来どおり評価する" do
      events = [
        span("MTG準備", "09:30", "11:00"),
        span("会食", "11:00", "12:00"), # 退勤側の除外キーワード
        span("休暇", "12:00", "19:00"),
      ]
      expect(plan_for(events)).to eq [t("09:30"), t("12:00"), false]
    end

    it "休暇イベントは業務イベントの判定から除外される（退勤の採用候補にならない）" do
      day = planner.call(date: date, events: [span("休暇", "15:00", "20:00")])
      expect(day.clock_out.plan.considered_events).to be_empty
      expect(day.clock_in.plan.considered_events).to be_empty
    end

    it "押し出しの根拠（どのイベントでどこからどこへ動かしたか）を返す" do
      day = planner.call(date: date, events: [span("午後休暇", "12:00", "19:00")])
      expect(day.clock_out.leave_shifts.map(&:label))
        .to eq ["休暇『午後休暇』(12:00-19:00) により 18:00 → 12:00"]
      expect(day.clock_in.leave_shifts).to be_empty
      expect(day.leaves.periods.map(&:label)).to eq ["『午後休暇』(12:00-19:00)"]
    end
  end

  # 揺らぎ（jitter）と休暇境界の相互作用を固定する。上の表は window=0 で押し出し自体を
  # 見ているため、ここで揺らぎを載せた実運用相当の設定を検証する。
  #
  # 設計判断（ユーザー承認済み）: 揺らぎは常に勤務時間を広げる向き（出勤＝締切から手前、
  # 退勤＝基準から後ろ）で、休暇の境界でも向きを反転しない。したがって休暇で押し出した
  # 締切・基準から揺らいだ目標は、休暇の時間帯の内側に入る（午前休なら休暇終了の直前に出勤、
  # 午後休なら休暇開始の直後に退勤）。「休暇境界では揺らぎを反転して常に休暇の外側にする」
  # 案は検討のうえ不採用。これは意図した挙動なので、黙って変えないこと。
  describe "揺らぎと休暇境界" do
    # 実運用に近い設定: 所定 09:25 + ウィンドウ5分 → 所定の打刻締切は 09:30 / 退勤は 18:00。
    let(:config) do
      Ak4Punch::Config.new(
        data: {
          "company_id" => "x",
          "work" => { "clock_in" => "09:25", "clock_out" => "18:00", "random_window_minutes" => 5 },
          "calendar" => { "enabled" => true, "exclude_keywords" => ["会食"] },
          "daemon" => { "manage_wake" => false, "late_grace_minutes" => 10, "morning_wake_at" => "07:45" },
        },
        root: Dir.pwd,
      )
    end

    # 日毎・kind毎に固定の揺らぎ秒（式は spec_helper の JitterHelper に集約）
    def jitter(kind, window: 5, day: 10)
      jitter_seconds_for(Date.new(2026, 7, day), kind, window)
    end

    def leaves_of(events)
      Ak4Punch::LeaveSchedule.build(events: events, keywords: config.calendar_leave_keywords, date: date)
    end

    it "午前休は「休暇の終了 − 揺らぎ」に出勤する（目標は休暇の時間帯の内側）" do
      events = [event(title: "午前休み", starts_at: t("09:00"), ends_at: t("13:00"))]

      day = planner.call(date: date, events: events)
      expect(day.clock_in.deadline).to eq t("13:00")             # 所定の締切 09:30 が休暇の外へ後ろ倒し
      expect(day.clock_in.target).to eq t("13:00") - jitter(:in) # 揺らぎは締切から手前＝休暇側へ戻る
      expect(day.clock_in.target).to be_between(t("12:55"), t("13:00"))
      expect(leaves_of(events).covers?(day.clock_in.target)).to be true
    end

    it "午後休は「休暇の開始 + 揺らぎ」に退勤する（目標は休暇の時間帯の内側）" do
      events = [event(title: "午後休暇", starts_at: t("12:00"), ends_at: t("19:00"))]

      day = planner.call(date: date, events: events)
      expect(day.clock_out.base).to eq t("12:00")                   # 所定 18:00 が休暇の外へ前倒し
      expect(day.clock_out.target).to eq t("12:00") + jitter(:out)  # 揺らぎは基準から後ろ＝休暇側へ入る
      expect(day.clock_out.target).to be_between(t("12:00"), t("12:05"))
      expect(leaves_of(events).covers?(day.clock_out.target)).to be true
    end

    it "休暇のない日は従来どおり所定の締切・基準から揺らぐ" do
      day = planner.call(date: date, events: [])
      expect(day.clock_in.target).to eq t("09:30") - jitter(:in)
      expect(day.clock_out.target).to eq t("18:00") + jitter(:out)
    end
  end

  # 退勤目標は「基準 + 揺らぎ」なので、基準が当日内でも目標が翌日に跨ることがある。
  # 翌日に出た目標は日付変化で計画が破棄され（Daemon#start_new_day）必ず未打刻になるため、
  # そういう日は揺らぎを落として基準そのものを目標にする（23:59:59 で頭を押さえるのでは、
  # tick（既定30秒）が日付変更までに入る余裕がなく、位相次第で結局打刻されない。
  # tick 側の検証は daemon_spec の同名 describe を参照）。
  describe "退勤目標が翌日に出る日は揺らぎを落とす" do
    let(:config) do
      Ak4Punch::Config.new(
        data: {
          "company_id" => "x",
          "work" => { "clock_in" => "09:25", "clock_out" => "18:00", "random_window_minutes" => 5 },
          "calendar" => { "enabled" => true },
          "daemon" => { "manage_wake" => false, "late_grace_minutes" => 10, "morning_wake_at" => "07:45" },
        },
        root: Dir.pwd,
      )
    end

    # 退勤側の揺らぎ秒（2026-07-10 は 183秒）
    def jitter_out(day: 10)
      jitter_seconds_for(Date.new(2026, 7, day), :out, 5)
    end

    it "23:59 終了のイベントの日は基準（23:59:00）が目標になる" do
      # 前提の確認: 揺らぎを足すと目標は翌日 00:02:03 になる
      expect(t("23:59") + jitter_out).to eq t("00:02", 3, day: 11)

      day = planner.call(date: date, events: [event(title: "障害対応", ends_at: t("23:59"))])
      expect(day.clock_out.base).to eq t("23:59")
      expect(day.clock_out.target).to eq t("23:59")      # 23:59:59 ではなく基準そのもの
      expect(day.clock_out.target.to_date).to eq date
      # 日付変更まで60秒あり、tick(30秒)がどの位相でも1回は入る
      expect(t("00:00", 0, day: 11) - day.clock_out.target).to be >= config.daemon_tick_seconds
    end

    it "落とした結果も基準を下回らない（退勤基準より前には打刻しない）" do
      day = planner.call(date: date, events: [event(title: "障害対応", ends_at: t("23:59"))])
      expect(day.clock_out.target).to be >= day.clock_out.base
    end

    it "当日内に収まる目標はそのまま（従来どおり基準+揺らぎ）" do
      day = planner.call(date: date, events: [event(title: "実装", ends_at: t("18:30"))])
      expect(day.clock_out.target).to eq t("18:30") + jitter_out
      expect(day.clock_out.plan.source).to eq :calendar
    end
  end

  describe "全休（休暇で勤務時間がなくなる日）" do
    let(:leave_event) { event(title: "夏季休暇", ends_at: nil, all_day: true) }

    it "全休フラグと休暇イベントの時間帯を返す" do
      day = planner.call(date: date, events: [leave_event])
      expect(day.full_leave?).to be true
      expect(day.leaves.periods.map { |p| p.event.title }).to eq ["夏季休暇"]
    end

    it "休暇がなければ全休でなく休暇イベントも空" do
      day = planner.call(date: date, events: [event(title: "実装", ends_at: t("18:30"))])
      expect(day.full_leave?).to be false
      expect(day.leaves.periods).to be_empty
    end
  end

  describe "calendar_enabled=false（連動OFF）" do
    let(:config) do
      Ak4Punch::Config.new(
        data: {
          "company_id" => "x",
          "work" => { "clock_in" => "09:30", "clock_out" => "18:00" },
          "calendar" => { "enabled" => false },
          "daemon" => { "manage_wake" => false },
        },
        root: Dir.pwd,
      )
    end

    # 連動OFF のとき呼び出し側（Daemon・CLI）は sukesan を取得せず events: nil を渡す。
    it "plan なし・error なし・所定時刻を返す" do
      day = planner.call(date: date, events: nil)
      expect(day.clock_out.plan).to be_nil
      expect(day.clock_out.error).to be_nil
      expect(day.clock_out.target).to eq t("18:00")
      expect(day.clock_in.plan).to be_nil
      expect(day.clock_in.error).to be_nil
      expect(day.clock_in.target).to eq t("09:30")
    end
  end

  describe "#call（当日計画の組み立て）" do
    it "イベントを反映した計画を返す" do
      events = [event(title: "実装", ends_at: t("19:00")), event(title: "会食", ends_at: t("21:00"))]
      day = planner.call(date: date, events: events)
      expect(day.date).to eq date
      expect(day.clock_in.target).to eq t("09:30")
      expect(day.clock_out.target).to eq t("19:00") # 会食は除外され実装採用
      expect(day.clock_out.plan.adopted_event.title).to eq "実装"
    end

    it "出勤側も判断根拠（plan / deadline）を返す" do
      # 朝の予定をアンカーにするには下限（morning_wake_at）を所定より前に置く必要がある
      cfg = Ak4Punch::Config.new(
        data: {
          "company_id" => "x",
          "work" => { "clock_in" => "09:30", "clock_out" => "18:00" },
          "calendar" => { "enabled" => true },
          "daemon" => { "manage_wake" => false, "morning_wake_at" => "07:45" },
        },
        root: Dir.pwd,
      )
      day = described_class.new(config: cfg, logger: logger).call(
        date: date, events: [event(title: "定例会議", starts_at: t("09:00"), ends_at: t("10:00"))],
      )
      expect(day.clock_in.plan.adopted_event.title).to eq "定例会議"
      expect(day.clock_in.deadline).to eq t("09:00")
      expect(day.clock_in.target).to eq t("09:00") # window=0 なので揺らぎなし
      expect(day.clock_in.error).to be_nil
    end

    it "morning_wake_at 未設定なら下限が所定出勤時刻になり、朝の予定はアンカーにならない" do
      # 既定 config は morning_wake_at 未設定
      day = planner.call(date: date, events: [event(title: "定例会議", starts_at: t("09:00"), ends_at: t("10:00"))])
      expect(day.clock_in.plan.adopted_event).to be_nil
      expect(day.clock_in.plan.too_early_events.map(&:title)).to eq ["定例会議"]
      expect(day.clock_in.deadline).to eq t("09:30") # 所定の締切のまま
      expect(day.clock_in.target).to eq t("09:30")
    end

    it "取得失敗（events なし + error あり）は error を持ち所定時刻へフォールバック" do
      day = planner.call(date: date, events: nil, error: "接続拒否")
      expect(day.clock_out.error).to include "接続拒否"
      expect(day.clock_out.target).to eq t("18:00")
      expect(day.clock_in.error).to include "接続拒否"
      expect(day.clock_in.target).to eq t("09:30")
    end
  end

  describe "#morning_wake_at（翌営業日の起床＋出勤アンカーの下限）" do
    def planner_with(daemon_config)
      cfg = Ak4Punch::Config.new(
        data: {
          "company_id" => "x",
          "work" => { "clock_in" => "09:25", "clock_out" => "18:00" },
          "calendar" => { "enabled" => true },
          "daemon" => { "manage_wake" => false }.merge(daemon_config),
        },
        root: Dir.pwd,
      )
      described_class.new(config: cfg, logger: logger)
    end

    it "未設定なら所定出勤時刻" do
      expect(planner_with({}).morning_wake_at(date)).to eq t("09:25")
    end

    it "所定より早い値を設定するとその時刻" do
      expect(planner_with("morning_wake_at" => "07:45").morning_wake_at(date)).to eq t("07:45")
    end

    it "所定より遅い値を設定しても所定出勤時刻より遅くはしない（min を取る）" do
      expect(planner_with("morning_wake_at" => "10:00").morning_wake_at(date)).to eq t("09:25")
    end
  end
end
