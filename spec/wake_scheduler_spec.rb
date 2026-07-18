# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::WakeScheduler do
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }
  let(:calls) { [] }   # 書き込み（schedule wake）で渡されたコマンド列
  let(:reads) { [] }   # 読み取り（pmset -g sched）が呼ばれた回数の記録
  # state で読み書きの成否と現在の予約状況を制御する。
  let(:state) { { read_ok: true, write_ok: true, sched: "" } }
  let(:runner) { ->(cmd) { calls << cmd; ["", state[:write_ok]] } }
  let(:reader) { -> { reads << :read; [state[:sched], state[:read_ok]] } }
  let(:now) { t("07:00") }
  let(:clock) { -> { now } }

  subject(:scheduler) do
    described_class.new(
      lead_minutes: 1, logger: logger, runner: runner, reader: reader, clock: clock
    )
  end

  def t(hhmm, day: 10)
    h, m = hhmm.split(":").map(&:to_i)
    Time.new(2026, 7, day, h, m, 0, "+09:00")
  end

  # `pmset -g sched` の Scheduled power events ブロックを組み立てる。
  def sched_output(*hhmms)
    lines = hhmms.each_with_index.map do |hhmm, i|
      " [#{i}]  wake at #{t(hhmm).strftime('%m/%d/%Y %H:%M:%S')} by 'pmset'"
    end
    (["Scheduled power events:"] + lines).join("\n") + "\n"
  end

  def wake_cmd(hhmm)
    ["sudo", "-n", "/usr/bin/pmset", "schedule", "wake", t(hhmm).strftime("%m/%d/%Y %H:%M:%S")]
  end

  # --- パーサ ---------------------------------------------------------
  describe ".parse_pmset_wakes" do
    let(:sample) do
      <<~SCHED
        Repeating power events:
          wakepoweron at 9:19AM Some days
        Scheduled power events:
         [0]  wake at 07/10/2026 09:29:00 by 'pmset'
         [1]  wake at 07/10/2026 18:29:00 by 'pmset'
         [2]  wake at 07/10/2026 23:00:00 by 'powerd'
      SCHED
    end

    it "by 'pmset' の wake 行だけを Time(JST) に変換する" do
      expect(described_class.parse_pmset_wakes(sample)).to contain_exactly(t("09:29"), t("18:29"))
    end

    it "他所有者・非 wake 行・繰返しイベント・不正な日時はスキップする" do
      text = <<~SCHED
         [0]  wake at 07/10/2026 09:29:00 by 'powerd'
         [1]  sleep at 07/10/2026 23:00:00 by 'pmset'
        まったく関係のない行
         [2]  wake at NOT-A-DATE by 'pmset'
         [3]  wake at 13/40/2026 99:99:99 by 'pmset'
      SCHED
      expect(described_class.parse_pmset_wakes(text)).to be_empty
    end

    it "空入力は空集合" do
      expect(described_class.parse_pmset_wakes("")).to be_empty
    end
  end

  # --- add-only 突き合わせ -------------------------------------------
  describe "#reschedule" do
    it "必要な wake が全て予約済みなら何もしない（コマンド0件・ログなし）" do
      state[:sched] = sched_output("09:29") # 09:30 の 1 分前は既に予約済み
      expect(logger).not_to receive(:info)
      scheduler.reschedule([t("09:30")])
      expect(calls).to be_empty
      expect(scheduler.disabled?).to be false
    end

    it "不足している wake だけを追加する（既存はそのまま・消さない）" do
      state[:sched] = sched_output("09:29")               # 09:29 は在る
      scheduler.reschedule([t("09:30"), t("18:30")])       # 18:29 が不足
      expect(calls).to eq [wake_cmd("18:29")]
    end

    it "何も予約されていなければ全件を昇順で追加する" do
      scheduler.reschedule([t("18:30"), t("09:30")])
      expect(calls).to eq [wake_cmd("09:29"), wake_cmd("18:29")]
    end

    it "重複する目標は1件にまとめて追加する（デデュープ）" do
      scheduler.reschedule([t("09:30"), t("09:30")])
      expect(calls).to eq [wake_cmd("09:29")]
    end

    it "lead 分前がちょうど現在時刻の目標は除外する（境界は未来のみ）" do
      # lead=1分。目標 07:01 の 1 分前 = 07:00 = now ちょうど → 追加しない。
      scheduler.reschedule([t("07:01")])
      expect(calls).to be_empty
    end

    it "同時刻に他所有者(by 'powerd')の予約があっても自分の追加判定に影響しない" do
      # 09:29 は powerd の予約。parse は by 'pmset' のみ拾うので自分の予約は無しと判定し、
      # desired 09:29 を通常どおり追加する（他所有者の予約は消さない・突き合わせに使わない）。
      state[:sched] = " [0]  wake at 07/10/2026 09:29:00 by 'powerd'\n"
      scheduler.reschedule([t("09:30")])
      expect(calls).to eq [wake_cmd("09:29")]
    end

    it "空配列なら書き込みは行わない（読み取りのみ）" do
      scheduler.reschedule([])
      expect(calls).to be_empty
      expect(reads).not_to be_empty
    end

    it "cancelall / cancel は一切実行しない" do
      scheduler.reschedule([t("09:30"), t("18:30")])
      expect(calls.flatten).not_to include("cancelall")
      expect(calls.flatten).not_to include("cancel")
    end

    context "lead 分前が現在時刻より過去のとき" do
      let(:now) { t("09:30") } # desired 09:29 < now

      it "その目標はスキップする" do
        scheduler.reschedule([t("09:30")])
        expect(calls).to be_empty
      end
    end

    it "読み取り失敗時は当日無効化せず、書き込みも試みない（次回再試行）" do
      state[:read_ok] = false
      expect(logger).to receive(:warn).with(/読み取りに失敗/)
      scheduler.reschedule([t("09:30")])
      expect(calls).to be_empty
      expect(scheduler.disabled?).to be false
    end

    it "wake 予約の書き込みに失敗したら当日無効化する（sudoers 未設定の可能性）" do
      state[:write_ok] = false
      expect(logger).to receive(:warn).with(/sudoers/)
      scheduler.reschedule([t("09:30"), t("18:30")])
      expect(scheduler.disabled?).to be true
      expect(calls.size).to eq 1 # 最初の1件で失敗して以降は中断
    end

    it "無効化後は reschedule しても読み取り・書き込みを一切しない" do
      state[:write_ok] = false
      scheduler.reschedule([t("09:30")])
      calls.clear
      reads.clear
      scheduler.reschedule([t("18:30")])
      expect(calls).to be_empty
      expect(reads).to be_empty
    end

    it "reset! で無効化を解除する" do
      state[:write_ok] = false
      scheduler.reschedule([t("09:30")])
      expect(scheduler.disabled?).to be true

      scheduler.reset!
      state[:write_ok] = true
      scheduler.reschedule([t("18:30")])
      expect(scheduler.disabled?).to be false
      expect(calls).not_to be_empty
    end
  end
end
