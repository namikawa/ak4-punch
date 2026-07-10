# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::Daemon do
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

  let(:stamper) { instance_double(Ak4Punch::Stamper) }
  let(:calendar) { instance_double(Ak4Punch::WorkCalendar) }
  let(:calendar_client) { instance_double(Ak4Punch::CalendarClient) }
  let(:token_store) { instance_double(Ak4Punch::TokenStore) }
  let(:client) { instance_double(Ak4Punch::Client) }
  let(:wake_scheduler) { instance_double(Ak4Punch::WakeScheduler) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }

  # 現在時刻を手で進められるクロック
  let(:clock_time) { { now: t("08:00") } }
  let(:clock) { -> { clock_time[:now] } }

  def event(title:, ends_at:, all_day: false, id: nil)
    Ak4Punch::CalendarClient::Event.new(
      id: id || "e#{title}", title: title, starts_at: nil, ends_at: ends_at,
      location: nil, all_day: all_day,
    )
  end

  subject(:daemon) do
    described_class.new(
      config: config, stamper: stamper, calendar: calendar, calendar_client: calendar_client,
      token_store: token_store, client: client, wake_scheduler: wake_scheduler, logger: logger,
      clock: clock, sleeper: ->(_s) {},
    )
  end

  before do
    allow(calendar).to receive(:reason).and_return(nil)      # 既定: 対象日
    allow(calendar).to receive(:target?).and_return(true)
    allow(wake_scheduler).to receive(:reset!)
    allow(wake_scheduler).to receive(:reschedule)
    allow(token_store).to receive(:needs_refresh?).and_return(false)
  end

  describe "due 到達で打刻" do
    it "出勤目標時刻に達したら出勤を打刻する（window=0で即時）" do
      allow(calendar_client).to receive(:events).with(date: date)
        .and_return([event(title: "実装", ends_at: t("18:30"))])

      clock_time[:now] = t("08:00")
      daemon.tick # 計画作成（出勤09:30 / 退勤18:30）

      expect(stamper).to receive(:punch).with(kind: :in, date: date, window_minutes: 0)
      clock_time[:now] = t("09:30", 5)
      daemon.tick
    end

    it "退勤はカレンダー連動の目標時刻に打刻する" do
      allow(calendar_client).to receive(:events).with(date: date)
        .and_return([event(title: "実装", ends_at: t("18:30"))])
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick

      expect(stamper).to receive(:punch).with(kind: :out, date: date, window_minutes: 0)
      clock_time[:now] = t("18:30", 10)
      daemon.tick
    end

    it "打刻前に needs_refresh? なら token を再発行する" do
      allow(calendar_client).to receive(:events).and_return([])
      allow(token_store).to receive(:needs_refresh?).and_return(true)
      expect(token_store).to receive(:refresh!).with(client)
      allow(stamper).to receive(:punch)

      daemon.tick
      clock_time[:now] = t("09:30", 1)
      daemon.tick
    end
  end

  describe "grace 超過でスキップ+警告" do
    it "目標+grace を過ぎたら打刻せず警告ログを出す" do
      allow(calendar_client).to receive(:events).and_return([])
      daemon.tick # 出勤09:30 / 退勤18:00

      expect(stamper).not_to receive(:punch).with(hash_including(kind: :in))
      allow(stamper).to receive(:punch) # 退勤は別tickで対象外
      expect(logger).to receive(:warn).with(/出勤目標.*超過.*打刻せず/)

      clock_time[:now] = t("09:41") # 09:30 + 10分grace を超過（+11分）
      daemon.tick
    end

    it "grace 内（目標+grace ちょうど手前）なら打刻する" do
      allow(calendar_client).to receive(:events).and_return([])
      daemon.tick

      expect(stamper).to receive(:punch).with(kind: :in, date: date, window_minutes: 0)
      clock_time[:now] = t("09:39", 59) # 09:30 + 9:59 < grace 10分
      daemon.tick
    end
  end

  describe "refresh で目標変更に追随" do
    it "再取得でイベントが伸びたら退勤目標を更新して再スケジュールする" do
      allow(calendar_client).to receive(:events).and_return(
        [event(title: "実装", ends_at: t("18:30"))], # 初回
        [event(title: "実装", ends_at: t("19:30"))], # 再取得後（延長）
      )

      clock_time[:now] = t("08:00")
      daemon.tick # 退勤目標 18:30

      # refresh 間隔(15分)経過後の tick で再取得され 19:30 に更新される
      expect(logger).to receive(:info).with(/退勤目標を更新.*18:30.*19:30/)
      clock_time[:now] = t("08:16")
      daemon.tick

      # 更新後の目標(19:30)で打刻される（18:30では打刻しない）
      allow(stamper).to receive(:punch).with(kind: :in, date: anything, window_minutes: 0)
      clock_time[:now] = t("18:30", 30)
      expect(stamper).not_to receive(:punch).with(kind: :out, date: anything, window_minutes: 0)
      daemon.tick
    end

    it "refresh 間隔前は再取得しない" do
      allow(calendar_client).to receive(:events).and_return([event(title: "実装", ends_at: t("18:30"))])
      clock_time[:now] = t("08:00")
      daemon.tick
      clock_time[:now] = t("08:10") # 15分未満
      daemon.tick
      expect(calendar_client).to have_received(:events).once
    end
  end

  describe "sukesan 障害時のフォールバック" do
    it "取得失敗時は所定退勤時刻へフォールバックする" do
      allow(calendar_client).to receive(:events)
        .and_raise(Ak4Punch::CalendarClient::ApiError, "接続拒否")
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick

      # 退勤は所定 18:00 で打刻される
      expect(stamper).to receive(:punch).with(kind: :out, date: date, window_minutes: 0)
      clock_time[:now] = t("18:00", 5)
      daemon.tick
    end
  end

  describe "非対象日は何もしない" do
    it "対象日でなければ計画せず打刻しない" do
      allow(calendar).to receive(:reason).and_return("祝日")
      allow(calendar).to receive(:target?).and_return(false)
      expect(calendar_client).not_to receive(:events)
      expect(stamper).not_to receive(:punch)

      clock_time[:now] = t("09:30", 30)
      daemon.tick
      clock_time[:now] = t("18:00", 30)
      daemon.tick
    end
  end

  describe "wake 予約" do
    it "計画作成時に未来の打刻目標＋翌営業日朝のブートストラップで wake を予約する" do
      allow(calendar_client).to receive(:events).and_return([event(title: "実装", ends_at: t("18:30"))])
      # calendar.target? は常に true スタブ → 翌営業日 = 翌日(7/11) の所定出勤時刻（揺らぎなし）
      expect(wake_scheduler).to receive(:reschedule).with([t("09:30"), t("18:30"), t("09:30", day: 11)])
      clock_time[:now] = t("08:00")
      daemon.tick
    end

    it "金曜: 当日の打刻が全て完了しても翌営業日(月曜)朝の予約を維持する" do
      allow(calendar).to receive(:target?) { |d| !d.saturday? && !d.sunday? } # 土日のみ非対象
      allow(calendar_client).to receive(:events).and_return([])
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick # 計画: 出勤09:30 / 退勤18:00（イベントなし→所定）

      clock_time[:now] = t("09:30", 5)
      daemon.tick # 出勤打刻 → done

      # 退勤完了後: 当日 targets は空になり、月曜(7/13)朝のブートストラップのみが残る
      expect(wake_scheduler).to receive(:reschedule).with([t("09:30", day: 13)])
      clock_time[:now] = t("18:00", 5)
      daemon.tick
    end

    it "祝日跨ぎ: 連休明けの営業日朝をブートストラップ予約する" do
      # 7/11〜7/14 は非対象（週末＋連休）、7/15(水) が次の営業日
      allow(calendar).to receive(:target?) { |d| d >= Date.new(2026, 7, 15) }
      allow(calendar_client).to receive(:events).and_return([])

      expect(wake_scheduler).to receive(:reschedule).with([t("09:30"), t("18:00"), t("09:30", day: 15)])
      clock_time[:now] = t("08:00")
      daemon.tick
    end

    it "done へ遷移した tick で予約し直し、遷移が無い tick では予約しない" do
      allow(calendar_client).to receive(:events).and_return([])
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick # 計画作成で1回
      expect(wake_scheduler).to have_received(:reschedule).once

      clock_time[:now] = t("08:05") # due なし・refresh 間隔前 → 遷移なし
      daemon.tick
      expect(wake_scheduler).to have_received(:reschedule).once # 増えない

      clock_time[:now] = t("09:30", 5) # 出勤 due → done 遷移
      daemon.tick
      expect(wake_scheduler).to have_received(:reschedule).twice
    end

    it "graceスキップによる done 遷移でも予約し直す" do
      allow(calendar_client).to receive(:events).and_return([])

      clock_time[:now] = t("08:00")
      daemon.tick # 計画作成で1回

      clock_time[:now] = t("09:41") # 出勤 grace 超過 → スキップ（done 遷移）
      daemon.tick
      expect(wake_scheduler).to have_received(:reschedule).twice
    end

    context "manage_wake=false" do
      let(:no_wake_daemon) do
        cfg = Ak4Punch::Config.new(
          data: { "company_id" => "x", "daemon" => { "manage_wake" => false }, "calendar" => { "enabled" => true } },
          root: Dir.pwd,
        )
        described_class.new(
          config: cfg, stamper: stamper, calendar: calendar, calendar_client: calendar_client,
          token_store: token_store, client: client, wake_scheduler: wake_scheduler, logger: logger,
          clock: clock, sleeper: ->(_s) {},
        )
      end

      it "対象日でも wake を触らない（reschedule を一切呼ばない）" do
        allow(calendar_client).to receive(:events).and_return([])
        expect(wake_scheduler).not_to receive(:reschedule)
        no_wake_daemon.tick
      end

      it "非対象日でも wake を触らない（reschedule を一切呼ばない）" do
        allow(calendar).to receive(:reason).and_return("週末")
        expect(calendar_client).not_to receive(:events)
        expect(wake_scheduler).not_to receive(:reschedule)
        no_wake_daemon.tick
      end
    end

    it "非対象日でも manage_wake=true なら翌営業日朝のブートストラップ予約が入る" do
      allow(calendar).to receive(:reason).and_return("祝日")
      allow(calendar).to receive(:target?) { |d| d == Date.new(2026, 7, 13) } # 次の営業日 = 月曜
      expect(wake_scheduler).to receive(:reschedule).with([t("09:30", day: 13)])
      daemon.tick
    end
  end

  describe "calendar_enabled=false（連動OFF）" do
    let(:disabled_daemon) do
      cfg = Ak4Punch::Config.new(
        data: {
          "company_id" => "x",
          "work" => { "clock_in" => "09:30", "clock_out" => "18:00" },
          "calendar" => { "enabled" => false },
          "daemon" => { "manage_wake" => false },
        },
        root: Dir.pwd,
      )
      described_class.new(
        config: cfg, stamper: stamper, calendar: calendar, calendar_client: calendar_client,
        token_store: token_store, client: client, wake_scheduler: wake_scheduler, logger: logger,
        clock: clock, sleeper: ->(_s) {},
      )
    end

    it "sukesan へ一切アクセスせず、退勤は所定時刻+揺らぎで打刻する" do
      expect(calendar_client).not_to receive(:events)

      clock_time[:now] = t("08:00")
      disabled_daemon.tick # 計画作成

      # refresh 間隔経過後の tick でも fetch されない
      clock_time[:now] = t("08:30")
      disabled_daemon.tick

      # 退勤は所定 18:00（window=0 なので揺らぎ0）で打刻される
      allow(stamper).to receive(:punch)
      expect(stamper).to receive(:punch).with(kind: :out, date: date, window_minutes: 0)
      clock_time[:now] = t("18:00", 5)
      disabled_daemon.tick
    end

    it "build_day_plan は連動OFF（plan なし・error なし・所定時刻）を返す" do
      expect(calendar_client).not_to receive(:events)
      day = disabled_daemon.build_day_plan(date: date)
      expect(day[:out_plan]).to be_nil
      expect(day[:out_error]).to be_nil
      expect(day[:out_target]).to eq t("18:00")
    end
  end

  describe "build_day_plan（plan コマンド用）" do
    it "対象日はイベントを反映した計画を返す" do
      allow(calendar_client).to receive(:events).with(date: date)
        .and_return([event(title: "実装", ends_at: t("19:00")), event(title: "会食", ends_at: t("21:00"))])
      day = daemon.build_day_plan(date: date)
      expect(day[:target?]).to be true
      expect(day[:in_target]).to eq t("09:30")
      expect(day[:out_target]).to eq t("19:00") # 会食は除外され実装採用
      expect(day[:out_plan].adopted_event.title).to eq "実装"
    end

    it "取得失敗時は out_error を持ち所定時刻へフォールバック" do
      allow(calendar_client).to receive(:events).and_raise(Ak4Punch::CalendarClient::ApiError, "接続拒否")
      day = daemon.build_day_plan(date: date)
      expect(day[:out_error]).to include "接続拒否"
      expect(day[:out_target]).to eq t("18:00")
    end
  end
end
