# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::Stamper do
  let(:config) { instance_double(Ak4Punch::Config, check_existing: true) }
  let(:calendar) { instance_double(Ak4Punch::WorkCalendar) }
  let(:client) { instance_double(Ak4Punch::Client) }
  subject(:stamper) { described_class.new(config: config, client: client, calendar: calendar) }

  let(:workday) { Date.new(2026, 7, 8) }
  let(:holiday) { Date.new(2026, 1, 1) }

  it "対象日で未打刻なら出勤を打刻する" do
    allow(calendar).to receive(:reason).with(workday).and_return(nil)
    allow(client).to receive(:latest_stamp_type).with(date: workday).and_return(nil)
    expect(client).to receive(:post_stamp).with(type: 11).and_return({ stamped_at: "2026/07/08 09:30:01" })

    result = stamper.punch(kind: :in, date: workday)
    expect(result.status).to eq :punched
    expect(result.recorded_at).to eq "2026/07/08 09:30:01"
  end

  it "非対象日はスキップ（打刻しない）" do
    allow(calendar).to receive(:reason).with(holiday).and_return("祝日")
    expect(client).not_to receive(:post_stamp)

    result = stamper.punch(kind: :in, date: holiday)
    expect(result.status).to eq :skipped
    expect(result.message).to include "祝日"
  end

  it "既に同種の打刻があればスキップ" do
    allow(calendar).to receive(:reason).with(workday).and_return(nil)
    allow(client).to receive(:latest_stamp_type).with(date: workday).and_return(11)
    expect(client).not_to receive(:post_stamp)

    result = stamper.punch(kind: :in, date: workday)
    expect(result.status).to eq :skipped
  end

  it "前営業日の退勤が当日日付にあっても、当日出勤後(最終打刻=出勤)なら退勤を打刻する" do
    allow(calendar).to receive(:reason).with(workday).and_return(nil)
    allow(client).to receive(:latest_stamp_type).with(date: workday).and_return(11) # 在席中
    expect(client).to receive(:post_stamp).with(type: 12).and_return({ stamped_at: "x" })

    result = stamper.punch(kind: :out, date: workday)
    expect(result.status).to eq :punched
  end

  it "最終打刻が退勤(退席中)なら退勤はスキップ（重複退勤しない）" do
    allow(calendar).to receive(:reason).with(workday).and_return(nil)
    allow(client).to receive(:latest_stamp_type).with(date: workday).and_return(12)
    expect(client).not_to receive(:post_stamp)

    result = stamper.punch(kind: :out, date: workday)
    expect(result.status).to eq :skipped
  end

  it "dry_run はネットワークを叩かない" do
    allow(calendar).to receive(:reason).with(workday).and_return(nil)
    expect(client).not_to receive(:latest_stamp_type)
    expect(client).not_to receive(:post_stamp)

    result = stamper.punch(kind: :in, date: workday, dry_run: true)
    expect(result.status).to eq :dry_run
  end

  it "force は対象日判定・重複チェックを無視して打刻する" do
    allow(calendar).to receive(:reason).with(holiday).and_return("祝日")
    expect(client).not_to receive(:latest_stamp_type)
    expect(client).to receive(:post_stamp).with(type: 12).and_return({ stamped_at: "x" })

    result = stamper.punch(kind: :out, date: holiday, force: true)
    expect(result.status).to eq :punched
  end

  describe "ランダム打刻ウィンドウ" do
    let(:slept) { [] }
    let(:sleeper) { ->(sec) { slept << sec } }
    # rng.rand(0..range) が常に range を返す → 待機は window の最大値になる
    let(:rng) { double("rng") }
    subject(:stamper) do
      described_class.new(config: config, client: client, calendar: calendar, sleeper: sleeper, rng: rng)
    end

    it "window>0 のとき 0..N分のランダム秒だけ待ってから打刻する" do
      allow(calendar).to receive(:reason).with(workday).and_return(nil)
      allow(rng).to receive(:rand).with(0..300).and_return(123)
      allow(client).to receive(:latest_stamp_type).with(date: workday).and_return(11)
      expect(client).to receive(:post_stamp).with(type: 12).and_return({ stamped_at: "x" })

      result = stamper.punch(kind: :out, date: workday, window_minutes: 5)
      expect(slept).to eq [123]
      expect(result.status).to eq :punched
    end

    it "待機後に冪等チェックし、待機中の打刻があればスキップ（打刻しない）" do
      allow(calendar).to receive(:reason).with(workday).and_return(nil)
      allow(rng).to receive(:rand).and_return(10)
      allow(client).to receive(:latest_stamp_type).with(date: workday).and_return(12)
      expect(client).not_to receive(:post_stamp)

      result = stamper.punch(kind: :out, date: workday, window_minutes: 5)
      expect(slept).to eq [10]
      expect(result.status).to eq :skipped
    end

    it "window=0 のときは待機しない" do
      allow(calendar).to receive(:reason).with(workday).and_return(nil)
      allow(client).to receive(:latest_stamp_type).with(date: workday).and_return(nil)
      allow(client).to receive(:post_stamp).and_return({ stamped_at: "x" })

      stamper.punch(kind: :in, date: workday, window_minutes: 0)
      expect(slept).to be_empty
    end

    it "dry_run は window>0 でも待機せず、記録予定にウィンドウを表示する" do
      allow(calendar).to receive(:reason).with(workday).and_return(nil)
      expect(client).not_to receive(:latest_stamp_type)
      expect(client).not_to receive(:post_stamp)

      result = stamper.punch(kind: :out, date: workday, dry_run: true, window_minutes: 5)
      expect(slept).to be_empty
      expect(result.status).to eq :dry_run
      expect(result.message).to include "0〜5分後"
    end
  end
end
