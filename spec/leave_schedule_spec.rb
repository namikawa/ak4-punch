# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::LeaveSchedule do
  let(:date) { Date.new(2026, 7, 13) }

  def t(hhmm, day: 13)
    h, m = hhmm.split(":").map(&:to_i)
    Time.new(2026, 7, day, h, m, 0, "+09:00")
  end

  def ev(title:, all_day: false, starts_at: nil, ends_at: nil)
    Ak4Punch::CalendarClient::Event.new(
      id: "x", title: title, starts_at: starts_at, ends_at: ends_at, location: nil, all_day: all_day,
    )
  end

  def build(events, keywords: %w[休み 休暇])
    described_class.build(events: events, keywords: keywords, date: date)
  end

  describe "休暇イベントの仕分け" do
    it "タイトルが部分一致するイベントを休暇、それ以外を業務イベントにする" do
      leave = ev(title: "午後休暇", starts_at: t("13:00"), ends_at: t("19:00"))
      work = ev(title: "実装レビュー", starts_at: t("10:00"), ends_at: t("11:00"))
      schedule = build([work, leave])

      expect(schedule.events).to eq [leave]
      expect(schedule.work_events).to eq [work]
      expect(schedule).to be_any
    end

    it "時間の閾値はない（2時間の休暇イベントも休暇として扱う）" do
      short = ev(title: "午後休み", starts_at: t("15:00"), ends_at: t("17:00"))
      expect(build([short]).events).to eq [short]
    end

    it "複数の休暇イベントを全て拾う（1件目で打ち切らない）" do
      am = ev(title: "午前休み", starts_at: t("09:00"), ends_at: t("12:00"))
      pm = ev(title: "午後休み", starts_at: t("13:00"), ends_at: t("19:00"))
      expect(build([am, pm]).events).to eq [am, pm]
    end

    it "title が nil・空のイベントは休暇にしない" do
      schedule = build([ev(title: nil, all_day: true), ev(title: "", all_day: true)])
      expect(schedule.events).to be_empty
      expect(schedule).not_to be_any
    end

    it "キーワードが空なら休暇なし" do
      schedule = build([ev(title: "夏季休暇", all_day: true)], keywords: [])
      expect(schedule.events).to be_empty
    end

    it "events が nil でも空の集合として扱える（連動OFF・取得失敗）" do
      schedule = build(nil)
      expect(schedule.events).to be_empty
      expect(schedule.work_events).to be_empty
      expect(schedule.push_after(t("09:30"))).to eq [t("09:30"), []]
    end
  end

  describe "#covers?（閉区間で判定）" do
    subject(:schedule) { build([ev(title: "午後休暇", starts_at: t("15:00"), ends_at: t("19:00"))]) }

    it "時間帯の中は true" do
      expect(schedule.covers?(t("17:00"))).to be true
    end

    it "端点（開始・終了ちょうど）も中とみなす" do
      expect(schedule.covers?(t("15:00"))).to be true
      expect(schedule.covers?(t("19:00"))).to be true
    end

    it "時間帯の外は false" do
      expect(schedule.covers?(t("14:59"))).to be false
      expect(schedule.covers?(t("19:01"))).to be false
    end
  end

  describe "#push_after（出勤締切を休暇の外へ後ろ倒し）" do
    it "休暇の時間帯に入っていたら終了時刻へ後ろ倒しする" do
      schedule = build([ev(title: "午前休み", starts_at: t("09:00"), ends_at: t("13:00"))])
      time, shifts = schedule.push_after(t("09:30"))

      expect(time).to eq t("13:00")
      expect(shifts.map(&:from)).to eq [t("09:30")]
      expect(shifts.map(&:to)).to eq [t("13:00")]
      expect(shifts.first.label).to eq "休暇『午前休み』(09:00-13:00) により 09:30 → 13:00"
    end

    it "時間帯の外なら動かさない" do
      schedule = build([ev(title: "午後休暇", starts_at: t("15:00"), ends_at: t("19:00"))])
      expect(schedule.push_after(t("09:30"))).to eq [t("09:30"), []]
    end

    it "押し出し先が別の休暇に入るなら連鎖して押し出す" do
      schedule = build([
        ev(title: "午前休み", starts_at: t("09:00"), ends_at: t("12:00")),
        ev(title: "昼休み", starts_at: t("12:00"), ends_at: t("13:00")),
      ])
      time, shifts = schedule.push_after(t("09:30"))

      expect(time).to eq t("13:00")
      expect(shifts.map(&:to)).to eq [t("12:00"), t("13:00")]
    end

    it "終了時刻ちょうどに乗っている場合は動かさない（空回りしない）" do
      schedule = build([ev(title: "朝の休み", starts_at: t("08:00"), ends_at: t("09:30"))])
      expect(schedule.push_after(t("09:30"))).to eq [t("09:30"), []]
    end
  end

  describe "#push_before（退勤基準を休暇の外へ前倒し）" do
    it "休暇の時間帯に入っていたら開始時刻へ前倒しする" do
      schedule = build([ev(title: "午後休暇", starts_at: t("12:00"), ends_at: t("19:00"))])
      time, shifts = schedule.push_before(t("18:00"))

      expect(time).to eq t("12:00")
      expect(shifts.first.label).to eq "休暇『午後休暇』(12:00-19:00) により 18:00 → 12:00"
    end

    it "終了時刻ちょうど（閉区間の端）でも前倒しする" do
      schedule = build([ev(title: "午後休暇", starts_at: t("15:00"), ends_at: t("18:00"))])
      expect(schedule.push_before(t("18:00")).first).to eq t("15:00")
    end

    it "開始時刻ちょうどに乗っている場合は動かさない（空回りしない）" do
      schedule = build([ev(title: "夜の休み", starts_at: t("18:00"), ends_at: t("19:00"))])
      expect(schedule.push_before(t("18:00"))).to eq [t("18:00"), []]
    end

    it "押し出し先が別の休暇に入るなら連鎖して前倒しする" do
      schedule = build([
        ev(title: "午前休み", starts_at: t("09:00"), ends_at: t("12:00")),
        ev(title: "午後休み", starts_at: t("12:00"), ends_at: t("18:00")),
      ])
      time, shifts = schedule.push_before(t("17:00"))

      expect(time).to eq t("09:00")
      expect(shifts.map(&:to)).to eq [t("12:00"), t("09:00")]
    end
  end

  describe "時間帯の正規化" do
    it "終日イベントは当日00:00〜翌日00:00の休暇として扱う" do
      schedule = build([ev(title: "夏季休暇", all_day: true)])
      period = schedule.periods.first

      expect(period.starts_at).to eq t("00:00")
      expect(period.ends_at).to eq t("00:00", day: 14)
      expect(period.range_label).to eq "終日"
      # 出勤締切は翌日00:00へ、退勤基準は当日00:00へ押し出される（＝全休になる組み合わせ）
      expect(schedule.push_after(t("09:30")).first).to eq t("00:00", day: 14)
      expect(schedule.push_before(t("18:00")).first).to eq t("00:00")
    end

    it "終日イベントの押し出しラベルは日付を添える（日を跨ぐため）" do
      schedule = build([ev(title: "夏季休暇", all_day: true)])
      shift = schedule.push_after(t("09:30")).last.first
      expect(shift.label).to eq "休暇『夏季休暇』(終日) により 09:30 → 07/14 00:00"
    end

    it "開始時刻が nil の休暇は当日00:00からとして扱う" do
      schedule = build([ev(title: "休暇", starts_at: nil, ends_at: t("13:00"))])
      expect(schedule.push_after(t("09:30")).first).to eq t("13:00")
    end

    it "終了時刻が nil の休暇は翌日00:00までとして扱う" do
      schedule = build([ev(title: "休暇", starts_at: t("13:00"), ends_at: nil)])
      expect(schedule.push_before(t("18:00")).first).to eq t("13:00")
    end
  end
end
