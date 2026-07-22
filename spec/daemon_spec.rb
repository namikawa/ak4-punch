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
  let(:notifier) { instance_double(Ak4Punch::SlackNotifier, notify: nil, retry_pending: nil) }

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
      notifier: notifier, clock: clock, sleeper: ->(_s) {},
    )
  end

  before do
    allow(calendar).to receive(:reason).and_return(nil)      # 既定: 対象日
    allow(calendar).to receive(:target?).and_return(true)
    allow(wake_scheduler).to receive(:reset!)
    allow(wake_scheduler).to receive(:reschedule)
    allow(token_store).to receive(:needs_refresh?).and_return(false)
    allow(stamper).to receive(:punch_recorded?).and_return(false) # 既定: 当日の打刻は未記録
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

    it "manage_wake=true なら毎 tick で起床予約を突き合わせる（自己回復のため add-only 呼び出し）" do
      allow(calendar_client).to receive(:events).and_return([])
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick # 計画作成
      expect(wake_scheduler).to have_received(:reschedule).once

      clock_time[:now] = t("08:05") # due なし・refresh 間隔前でも突き合わせは走る
      daemon.tick
      expect(wake_scheduler).to have_received(:reschedule).twice

      clock_time[:now] = t("09:30", 5) # 出勤 due → done 遷移。ここでも突き合わせる
      daemon.tick
      expect(wake_scheduler).to have_received(:reschedule).exactly(3).times
    end

    it "grace スキップ（done 遷移）を挟んだ tick でも突き合わせる" do
      allow(calendar_client).to receive(:events).and_return([])

      clock_time[:now] = t("08:00")
      daemon.tick # 計画作成

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

  describe "打刻リトライと通知" do
    it "打刻失敗は done にせず次の tick で再試行し、成功したら完了する（通知なし）" do
      allow(calendar_client).to receive(:events).and_return([])
      calls = 0
      allow(stamper).to receive(:punch) do
        calls += 1
        raise Ak4Punch::Client::ApiError, "一時エラー" if calls == 1

        :ok
      end

      clock_time[:now] = t("08:00")
      daemon.tick # 計画作成

      clock_time[:now] = t("09:30", 5)
      daemon.tick # 1回目: 失敗（done にならない）
      expect(logger).to have_received(:error).with(/出勤の打刻に失敗.*再試行/)

      clock_time[:now] = t("09:30", 35)
      daemon.tick # 2回目: 成功
      expect(stamper).to have_received(:punch).twice
      expect(notifier).not_to have_received(:notify)

      clock_time[:now] = t("09:31", 5)
      daemon.tick # done 済み → 再打刻しない
      expect(stamper).to have_received(:punch).twice
    end

    it "窓内のリトライが尽きたら枯渇の文言で通知して諦める" do
      allow(calendar_client).to receive(:events).and_return([])
      allow(stamper).to receive(:punch).and_raise(Ak4Punch::Client::ApiError, "HTTP 500")

      clock_time[:now] = t("08:00")
      daemon.tick
      clock_time[:now] = t("09:30", 5)
      daemon.tick # 失敗1
      clock_time[:now] = t("09:35")
      daemon.tick # 失敗2
      clock_time[:now] = t("09:41") # 窓（grace 10分）超過
      daemon.tick

      expect(logger).to have_received(:warn).with(/出勤打刻はリトライ上限.*諦めます.*HTTP 500/)
      expect(notifier).to have_received(:notify)
        .with(/出勤打刻に失敗しました.*最後のエラー.*HTTP 500.*AKASHI で手動打刻してください/).once

      # 諦めた後は打刻しない
      punched = 0
      allow(stamper).to receive(:punch) { punched += 1 }
      clock_time[:now] = t("09:42")
      daemon.tick
      expect(punched).to eq 0
    end

    it "未試行の寝過ごしはスキップの文言で通知する（目標・現在時刻・実超過分を含む）" do
      allow(calendar_client).to receive(:events).and_return([])
      expect(stamper).not_to receive(:punch).with(hash_including(kind: :in))
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick
      clock_time[:now] = t("09:41") # due 到達時点で既に grace 超過・未試行（目標09:30 → 実超過11分）
      daemon.tick

      expect(notifier).to have_received(:notify)
        .with(/出勤打刻をスキップしました.*目標 09:30.*現在 09:41.*11分超過.*AKASHI で手動打刻してください/).once
    end

    it "grace 超過でも既にAKASHIで打刻済みならスキップ通知を出さず done にする（再起動時の誤通知防止）" do
      allow(calendar_client).to receive(:events).and_return([])
      allow(stamper).to receive(:punch_recorded?).with(:in, date).and_return(true) # 出勤は当日記録済み
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick # 計画作成（出勤09:30）
      clock_time[:now] = t("09:41") # 通常なら「寝過ごしスキップ」で誤通知するタイミング
      daemon.tick

      expect(notifier).not_to have_received(:notify)
      expect(stamper).not_to have_received(:punch).with(hash_including(kind: :in))

      clock_time[:now] = t("09:42") # done 済みなので後続 tick でも打刻・通知しない
      daemon.tick
      expect(notifier).not_to have_received(:notify)
    end

    it "退勤まで完了した日に退勤後に再起動しても出勤・退勤とも通知しない（誤通知防止・退勤後）" do
      allow(calendar_client).to receive(:events).and_return([])
      # AKASHI 履歴上は出勤・退勤とも記録済み（[出勤,退勤]の正常完了日）
      allow(stamper).to receive(:punch_recorded?).with(:in, date).and_return(true)
      allow(stamper).to receive(:punch_recorded?).with(:out, date).and_return(true)
      allow(stamper).to receive(:punch)

      # 退勤後(18:30)相当で最初の tick（＝再起動直後）。出勤(目標09:30)・退勤(目標18:00)とも
      # grace 超過だが、履歴上は完了しているので give_up で通知しない。
      clock_time[:now] = t("18:30")
      daemon.tick

      expect(notifier).not_to have_received(:notify)
    end

    it "AKASHI 確認が失敗したら安全側で通知する（確認不能なら黙殺しない）" do
      allow(calendar_client).to receive(:events).and_return([])
      allow(stamper).to receive(:punch_recorded?).and_raise(Ak4Punch::Client::ApiError, "HTTP 503")
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick
      clock_time[:now] = t("09:41")
      daemon.tick

      expect(notifier).to have_received(:notify)
        .with(/出勤打刻をスキップしました.*AKASHI で手動打刻してください/).once
    end

    it "Stamper の冪等スキップ（例外なし）は成功として完了する（通知なし）" do
      allow(calendar_client).to receive(:events).and_return([])
      allow(stamper).to receive(:punch)
        .and_return(Ak4Punch::Stamper::Result.new(status: :skipped, kind: :in, type: 11, message: "打刻済み"))

      clock_time[:now] = t("08:00")
      daemon.tick
      clock_time[:now] = t("09:30", 5)
      daemon.tick

      clock_time[:now] = t("09:31")
      daemon.tick # done 済み → 再試行しない
      expect(stamper).to have_received(:punch).once
      expect(notifier).not_to have_received(:notify)
    end

    it "トークン再発行失敗は打刻失敗としてリトライし、通知は同日1回だけ" do
      allow(calendar_client).to receive(:events).and_return([])
      allow(token_store).to receive(:needs_refresh?).and_return(true)
      allow(token_store).to receive(:refresh!).and_raise(RuntimeError, "トークン失効")
      expect(stamper).not_to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick
      clock_time[:now] = t("09:30", 5)
      daemon.tick # 失敗1（通知）
      clock_time[:now] = t("09:30", 35)
      daemon.tick # 失敗2（リトライは継続・通知なし）

      expect(token_store).to have_received(:refresh!).twice
      expect(notifier).to have_received(:notify)
        .with(/トークンの再発行に失敗しました.*トークン失効.*マイページでの再発行/).once
    end

    it "sukesan フォールバック通知は同日1回だけ（再取得の失敗で連打しない）" do
      allow(calendar_client).to receive(:events)
        .and_raise(Ak4Punch::CalendarClient::ApiError, "接続拒否")

      clock_time[:now] = t("08:00")
      daemon.tick # 計画時失敗 → 通知1回目
      clock_time[:now] = t("08:20") # refresh 間隔(15分)経過 → 再取得も失敗
      daemon.tick
      clock_time[:now] = t("08:40")
      daemon.tick

      expect(notifier).to have_received(:notify)
        .with(/sukesan からのイベント取得に失敗し、退勤は所定時刻にフォールバック.*接続拒否/).once
    end
  end

  describe "退勤直前の最終チェック" do
    # 定期 refresh の干渉を避けるため間隔を大きくし、due 時の fetch が最終チェック由来であることを保証する
    let(:config) do
      Ak4Punch::Config.new(
        data: {
          "company_id" => "x",
          "work" => { "clock_in" => "09:30", "clock_out" => "18:00" },
          "calendar" => { "enabled" => true, "exclude_keywords" => ["会食"], "refresh_interval_minutes" => 999 },
          "daemon" => { "tick_seconds" => 30, "late_grace_minutes" => 10, "manage_wake" => true, "wake_lead_minutes" => 1 },
        },
        root: Dir.pwd,
      )
    end

    it "目標が延長されていたら打刻せず延期し、新目標到達時に打刻する" do
      ends = { at: t("18:30") }
      allow(calendar_client).to receive(:events) { [event(title: "実装", ends_at: ends[:at])] }
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick # 計画: 出勤09:30 / 退勤18:30

      clock_time[:now] = t("09:30", 5)
      daemon.tick # 出勤打刻

      ends[:at] = t("19:00") # 直前に会議が延長された
      clock_time[:now] = t("18:30", 10)
      daemon.tick # due → 最終チェックで延長検出 → 延期

      # 退勤はまだ打刻されず、目標更新ログと wake 再予約（新目標＋ブートストラップ）が行われる
      expect(stamper).not_to have_received(:punch).with(kind: :out, date: date, window_minutes: 0)
      expect(logger).to have_received(:info).with(/退勤直前チェック.*延期/)
      expect(logger).to have_received(:info).with(/退勤目標を更新.*18:30.*19:00/)
      expect(wake_scheduler).to have_received(:reschedule).with([t("19:00"), t("09:30", day: 11)])

      clock_time[:now] = t("19:00", 5)
      daemon.tick # 新目標 due → 最終チェック（不変）→ 打刻
      expect(stamper).to have_received(:punch).with(kind: :out, date: date, window_minutes: 0)
    end

    it "目標が不変ならその tick で打刻する" do
      allow(calendar_client).to receive(:events).and_return([event(title: "実装", ends_at: t("18:30"))])
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick

      expect(stamper).to receive(:punch).with(kind: :out, date: date, window_minutes: 0)
      clock_time[:now] = t("18:30", 10)
      daemon.tick
      # fetch は計画作成時＋最終チェックの2回（定期 refresh は間隔999分で走らない）
      expect(calendar_client).to have_received(:events).twice
    end

    it "最終チェックの再取得が失敗したら警告つきで現在の目標のまま打刻する" do
      calls = 0
      allow(calendar_client).to receive(:events) do
        calls += 1
        raise Ak4Punch::CalendarClient::ApiError, "接続拒否" if calls > 1

        [event(title: "実装", ends_at: t("18:30"))]
      end
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick # 計画: 退勤18:30

      clock_time[:now] = t("18:30", 10)
      daemon.tick # due → 最終チェック失敗 → 現在の目標のまま打刻
      expect(logger).to have_received(:warn).with(/退勤直前チェック.*現在の目標のまま/)
      expect(stamper).to have_received(:punch).with(kind: :out, date: date, window_minutes: 0)
    end

    it "出勤の due では再取得しない" do
      allow(calendar_client).to receive(:events).and_return([event(title: "実装", ends_at: t("18:30"))])
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick # 計画作成で1回 fetch

      clock_time[:now] = t("09:30", 5)
      daemon.tick # 出勤 due → 打刻（最終チェックは走らない）
      expect(calendar_client).to have_received(:events).once
      expect(stamper).to have_received(:punch).with(kind: :in, date: date, window_minutes: 0)
    end

    it "calendar_enabled=false なら最終チェックなしで従来どおり打刻する" do
      cfg = Ak4Punch::Config.new(
        data: {
          "company_id" => "x",
          "work" => { "clock_in" => "09:30", "clock_out" => "18:00" },
          "calendar" => { "enabled" => false },
          "daemon" => { "manage_wake" => false },
        },
        root: Dir.pwd,
      )
      d = described_class.new(
        config: cfg, stamper: stamper, calendar: calendar, calendar_client: calendar_client,
        token_store: token_store, client: client, wake_scheduler: wake_scheduler, logger: logger,
        clock: clock, sleeper: ->(_s) {},
      )
      expect(calendar_client).not_to receive(:events)
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      d.tick # 計画作成（fetch なし）

      expect(stamper).to receive(:punch).with(kind: :out, date: date, window_minutes: 0)
      clock_time[:now] = t("18:00", 5)
      d.tick # due → 最終チェックなし → そのまま打刻
    end

    it "退勤リトライ中は最終チェックを再実行しない（同一目標では初回 due 時のみ）" do
      allow(calendar_client).to receive(:events).and_return([event(title: "実装", ends_at: t("18:30"))])
      out_calls = 0
      allow(stamper).to receive(:punch) do |kind:, **|
        if kind == :out
          out_calls += 1
          raise Ak4Punch::Client::ApiError, "一時エラー" if out_calls <= 2
        end
        :ok
      end

      clock_time[:now] = t("08:00")
      daemon.tick # 計画作成（fetch 1回目）

      clock_time[:now] = t("09:30", 5)
      daemon.tick # 出勤打刻（最終チェックなし）

      clock_time[:now] = t("18:30", 10)
      daemon.tick # 退勤 due → 最終チェック（fetch 2回目）→ 打刻失敗1
      clock_time[:now] = t("18:30", 40)
      daemon.tick # リトライ: fetch なしで打刻失敗2
      clock_time[:now] = t("18:31", 10)
      daemon.tick # リトライ: fetch なしで打刻成功

      expect(calendar_client).to have_received(:events).twice
      expect(out_calls).to eq 3
      expect(notifier).not_to have_received(:notify)
    end

    it "最終チェックで休暇イベントを検知したら打刻を中止する" do
      evs = { list: [event(title: "実装", ends_at: t("18:30"))] }
      allow(calendar_client).to receive(:events) { evs[:list] }
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick # 通常計画（退勤18:30）

      evs[:list] = [event(title: "午後休暇", ends_at: nil, all_day: true)] # 直前に休暇イベントが入った
      clock_time[:now] = t("18:30", 10)
      daemon.tick # due → 最終チェックで休暇検知 → 中止
      expect(logger).to have_received(:warn).with(/休暇イベント『午後休暇』を検知したため、以降の打刻を中止します/)
      expect(stamper).not_to have_received(:punch).with(kind: :out, date: date, window_minutes: 0)

      # 以降の tick でも打刻されない（休暇日として保持）
      clock_time[:now] = t("18:35")
      daemon.tick
      expect(stamper).not_to have_received(:punch).with(kind: :out, date: date, window_minutes: 0)
    end
  end

  describe "休暇の自動検知" do
    let(:leave_event) { event(title: "夏季休暇", ends_at: nil, all_day: true) }

    it "計画時に休暇を検知したら打刻計画を作らず、以降のtickでも再取得・打刻しない" do
      allow(calendar_client).to receive(:events).and_return([leave_event])
      expect(stamper).not_to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick # 計画時に休暇検知
      expect(logger).to have_received(:info).with(/休暇イベント『夏季休暇』を検知したため、本日は打刻しません/)
      # 打刻計画なし＝翌営業日ブートストラップのみ予約される
      expect(wake_scheduler).to have_received(:reschedule).with([t("09:30", day: 11)])

      # 休暇日として保持中: refresh も due 判定も停止（fetch は計画時の1回だけ）
      clock_time[:now] = t("09:30", 5)
      daemon.tick
      clock_time[:now] = t("18:00", 5)
      daemon.tick
      expect(calendar_client).to have_received(:events).once
    end

    it "日中の再取得で休暇を検知したら残りの打刻を中止する（打刻済み分はそのまま）" do
      evs = { list: [event(title: "実装", ends_at: t("18:30"))] }
      allow(calendar_client).to receive(:events) { evs[:list] }
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick # 通常計画（出勤09:30 / 退勤18:30）

      clock_time[:now] = t("09:30", 5)
      daemon.tick # 出勤打刻

      evs[:list] = [leave_event] # 出勤後に休暇イベントが入った
      clock_time[:now] = t("10:00")
      daemon.tick # refresh 間隔経過 → 再取得で休暇検知
      expect(logger).to have_received(:warn)
        .with(/休暇イベント『夏季休暇』を検知したため、以降の打刻を中止します。打刻済みの分は手動で削除してください/)

      clock_time[:now] = t("18:30", 5)
      daemon.tick # 退勤は打刻されない
      expect(stamper).to have_received(:punch).with(kind: :in, date: date, window_minutes: 0)
      expect(stamper).not_to have_received(:punch).with(kind: :out, date: date, window_minutes: 0)
    end

    it "recheck 要求で再計画し、休暇イベントが消えていれば通常計画に復帰する" do
      evs = { list: [event(title: "全休", ends_at: nil, all_day: true)] }
      allow(calendar_client).to receive(:events) { evs[:list] }
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick # 休暇日として計画なし

      evs[:list] = [] # カレンダー修正（休暇イベントを削除）
      daemon.request_recheck!
      clock_time[:now] = t("08:05")
      daemon.tick # 再計画 → 通常営業日に復帰
      expect(logger).to have_received(:info).with(/再チェック要求を受け付けました。本日の計画を再作成します/)
      expect(logger).to have_received(:info).with(/出勤目標を設定/)

      clock_time[:now] = t("09:30", 5)
      daemon.tick
      expect(stamper).to have_received(:punch).with(kind: :in, date: date, window_minutes: 0)
    end

    it "取得失敗時は休暇判定せず通常営業日として計画する（所定時刻フォールバック）" do
      allow(calendar_client).to receive(:events)
        .and_raise(Ak4Punch::CalendarClient::ApiError, "接続拒否")

      clock_time[:now] = t("08:00")
      daemon.tick
      expect(logger).to have_received(:info).with(/出勤目標を設定/)
      expect(logger).to have_received(:info).with(/退勤目標を設定.*フォールバック/)
    end

    it "calendar_enabled=false なら休暇検知しない（fetch もせず通常打刻）" do
      cfg = Ak4Punch::Config.new(
        data: {
          "company_id" => "x",
          "work" => { "clock_in" => "09:30", "clock_out" => "18:00" },
          "calendar" => { "enabled" => false },
          "daemon" => { "manage_wake" => false },
        },
        root: Dir.pwd,
      )
      d = described_class.new(
        config: cfg, stamper: stamper, calendar: calendar, calendar_client: calendar_client,
        token_store: token_store, client: client, wake_scheduler: wake_scheduler, logger: logger,
        clock: clock, sleeper: ->(_s) {},
      )
      expect(calendar_client).not_to receive(:events)
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      d.tick

      clock_time[:now] = t("09:30", 5)
      d.tick
      expect(stamper).to have_received(:punch).with(kind: :in, date: date, window_minutes: 0)
    end

    it "build_day_plan は検知した休暇イベントを leave_event として返す" do
      allow(calendar_client).to receive(:events).and_return([leave_event])
      day = daemon.build_day_plan(date: date)
      expect(day[:leave_event]&.title).to eq "夏季休暇"
    end

    it "build_day_plan は休暇がなければ leave_event なし" do
      allow(calendar_client).to receive(:events).and_return([event(title: "実装", ends_at: t("18:30"))])
      day = daemon.build_day_plan(date: date)
      expect(day[:leave_event]).to be_nil
    end
  end

  describe "日跨ぎ時の未打刻通知" do
    it "未完了(退勤)が残ったまま日付を跨いだら警告＋通知し、新しい日の計画は通常どおり作られる" do
      allow(calendar_client).to receive(:events).and_return([event(title: "実装", ends_at: t("18:30"))])
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick # 7/10 計画: 出勤09:30 / 退勤18:30

      clock_time[:now] = t("09:30", 5)
      daemon.tick # 出勤のみ打刻（退勤は未打刻のまま）

      # 翌日(7/11)の最初の tick で日付切替を検知 → 前日の未完了(退勤)を通知
      clock_time[:now] = t("08:00", day: 11)
      daemon.tick
      expect(logger).to have_received(:warn).with(/昨日（2026-07-10）の退勤が未打刻のまま日付が変わりました/)
      expect(notifier).to have_received(:notify)
        .with(/昨日（2026-07-10）の退勤は打刻されませんでした.*未打刻のまま日付が変わりました.*AKASHI で手動申請してください/).once
      # 出勤は打刻済み(done)なので通知されない
      expect(notifier).not_to have_received(:notify).with(/出勤は打刻されませんでした/)
      # 新しい日の計画は通常どおり作られる
      expect(logger).to have_received(:info).with(/出勤目標を設定/).twice
    end

    it "前日分が全て done なら通知しない" do
      allow(calendar).to receive(:target?) { |d| !d.saturday? && !d.sunday? }
      allow(calendar_client).to receive(:events).and_return([])
      allow(stamper).to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick # 計画: 出勤09:30 / 退勤18:00
      clock_time[:now] = t("09:30", 5)
      daemon.tick # 出勤 done
      clock_time[:now] = t("18:00", 5)
      daemon.tick # 退勤 done

      clock_time[:now] = t("08:00", day: 11) # 翌日
      daemon.tick
      expect(notifier).not_to have_received(:notify)
      expect(logger).not_to have_received(:warn).with(/未打刻のまま日付が変わりました/)
    end

    it "前日の未打刻でも AKASHI に打刻があれば通知しない（再起動後の突き合わせ・手動打刻）" do
      allow(calendar_client).to receive(:events).and_return([event(title: "実装", ends_at: t("18:30"))])
      allow(stamper).to receive(:punch)
      allow(stamper).to receive(:punch_recorded?).with(:out, date).and_return(true) # 退勤は当日記録済み

      clock_time[:now] = t("08:00")
      daemon.tick # 7/10 計画（出勤09:30 / 退勤18:30）
      clock_time[:now] = t("09:30", 5)
      daemon.tick # 出勤のみ打刻（退勤は @punch_plans 上は未完了のまま）

      clock_time[:now] = t("08:00", day: 11)
      daemon.tick # 日跨ぎ → 未打刻チェックだが AKASHI に退勤あり → 通知しない

      expect(notifier).not_to have_received(:notify)
      expect(logger).not_to have_received(:warn).with(/未打刻のまま日付が変わりました/)
    end

    it "前日が休暇日なら計画が無いので通知しない" do
      leave = event(title: "夏季休暇", ends_at: nil, all_day: true)
      allow(calendar_client).to receive(:events).and_return([leave])
      expect(stamper).not_to receive(:punch)

      clock_time[:now] = t("08:00")
      daemon.tick # 休暇日として計画なし

      clock_time[:now] = t("08:00", day: 11) # 翌日
      daemon.tick
      expect(notifier).not_to have_received(:notify)
      expect(logger).not_to have_received(:warn).with(/未打刻のまま日付が変わりました/)
    end

    it "前日が非対象日（計画なし）なら通知しない" do
      allow(calendar).to receive(:reason).and_return("週末")
      allow(calendar).to receive(:target?).and_return(false)

      clock_time[:now] = t("08:00")
      daemon.tick # 非対象日として計画なし

      clock_time[:now] = t("08:00", day: 11)
      daemon.tick
      expect(notifier).not_to have_received(:notify)
    end
  end

  describe "tick 毎に retry_pending を呼ぶ" do
    it "各 tick の冒頭で notifier.retry_pending が呼ばれる" do
      allow(calendar_client).to receive(:events).and_return([])

      clock_time[:now] = t("08:00")
      daemon.tick
      clock_time[:now] = t("08:05")
      daemon.tick
      expect(notifier).to have_received(:retry_pending).twice
    end
  end

  describe ".find_pid" do
    it "pgrep 結果から生存しているデーモンの PID を返す" do
      pid = described_class.find_pid(
        pgrep: -> { "111\n222\n" },
        alive: ->(p) { p == 222 },
        own_pid: 999,
      )
      expect(pid).to eq 222
    end

    it "自プロセスは除外する" do
      pid = described_class.find_pid(pgrep: -> { "111\n" }, alive: ->(_p) { true }, own_pid: 111)
      expect(pid).to be_nil
    end

    it "見つからなければ nil" do
      expect(described_class.find_pid(pgrep: -> { "" }, alive: ->(_p) { true }, own_pid: 1)).to be_nil
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
