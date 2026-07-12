# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::WakeScheduler do
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }
  let(:calls) { [] }
  # runner: 成功/失敗を制御できるモック実行器
  let(:results) { { ok: true } }
  let(:runner) do
    lambda do |cmd|
      calls << cmd
      ["", results[:ok]]
    end
  end

  subject(:scheduler) { described_class.new(lead_minutes: 1, logger: logger, runner: runner) }

  def t(hhmm)
    h, m = hhmm.split(":").map(&:to_i)
    Time.new(2026, 7, 10, h, m, 0, "+09:00")
  end

  it "cancelall 後に各目標の lead 分前を wake 予約する" do
    scheduler.reschedule([t("18:30"), t("09:30")])
    expect(calls[0]).to eq %w[sudo -n /usr/bin/pmset schedule cancelall]
    # ソートされ 09:29 → 18:29 の順（1分前）
    expect(calls[1]).to eq ["sudo", "-n", "/usr/bin/pmset", "schedule", "wake", "07/10/2026 09:29:00"]
    expect(calls[2]).to eq ["sudo", "-n", "/usr/bin/pmset", "schedule", "wake", "07/10/2026 18:29:00"]
  end

  it "cancelall が失敗（sudoers未設定）したら当日無効化し警告する" do
    results[:ok] = false
    expect(logger).to receive(:warn).with(/sudoers/)
    scheduler.reschedule([t("18:30")])

    expect(scheduler.disabled?).to be true
    # cancelall の1回のみ試行、wake は呼ばれない
    expect(calls.size).to eq 1
  end

  it "無効化後は reschedule しても何もしない" do
    results[:ok] = false
    scheduler.reschedule([t("18:30")])
    calls.clear
    scheduler.reschedule([t("09:30")])
    expect(calls).to be_empty
  end

  it "reset! で無効化を解除する" do
    results[:ok] = false
    scheduler.reschedule([t("18:30")])
    expect(scheduler.disabled?).to be true

    scheduler.reset!
    results[:ok] = true
    scheduler.reschedule([t("09:30")])
    expect(scheduler.disabled?).to be false
    expect(calls).not_to be_empty
  end

  it "空配列なら cancelall だけ実行する" do
    scheduler.reschedule([])
    expect(calls).to eq [%w[sudo -n /usr/bin/pmset schedule cancelall]]
  end
end
