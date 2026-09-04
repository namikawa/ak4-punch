# frozen_string_literal: true

require "webmock/rspec"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ak4_punch"

WebMock.disable_net_connect!

# 各 spec で共用するヘルパ。
module SpecHelpers
  # 2026-07-<day> の HH:MM:SS を JST の Time にする（既定は 2026-07-10 金曜）。
  # 日付・曜日に依存するテスト（祝日・週末・翌日跨ぎ）だけが day: を指定する。
  def t(hhmm, sec = 0, day: 10)
    h, m = hhmm.split(":").map(&:to_i)
    Time.new(2026, 7, day, h, m, sec, "+09:00")
  end

  # CalendarClient::Event（sukesan の応答から作られる構造体）。
  # ロジックは id を使わない（`punch plan` の一覧だけが equal? で照合する）ので既定値は固定文字列。
  def event(title:, starts_at: nil, ends_at: nil, all_day: false, id: nil)
    Ak4Punch::CalendarClient::Event.new(
      id: id || "e#{title}", title: title, starts_at: starts_at, ends_at: ends_at,
      all_day: all_day,
    )
  end

  # 揺らぎ（jitter）の期待値。DayPlanner#jitter_seconds と同じ導出を spec 側にも持つが、
  # 式の定義はこの1箇所だけにする（daemon_spec / day_planner_spec の双方から使う。
  # 式が各所にコピーされていると、目標時刻を動かす変更が入ったときに片方だけ直して
  # 「spec は通るのに目標がずれている」状態を作れてしまう）。
  # date: 対象日(Date) / kind: :in or :out / window: ウィンドウ(分)
  def jitter_seconds_for(date, kind, window)
    seed = Time.new(date.year, date.month, date.day, 0, 0, 0, Ak4Punch::JST).to_i ^
           Ak4Punch::DayPlanner::KIND_SALT.fetch(kind)
    Random.new(seed).rand(0..(window * 60))
  end
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |m| m.verify_partial_doubles = true }
  config.disable_monkey_patching!
  config.include SpecHelpers
end
