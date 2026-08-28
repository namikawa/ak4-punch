# frozen_string_literal: true

require "webmock/rspec"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ak4_punch"

WebMock.disable_net_connect!

# 揺らぎ（jitter）の期待値。DayPlanner#jitter_seconds と同じ導出を spec 側にも持つが、
# 式の定義はこの1箇所だけにする（daemon_spec / day_planner_spec の双方から使う。
# 式が各所にコピーされていると、目標時刻を動かす変更が入ったときに片方だけ直して
# 「spec は通るのに目標がずれている」状態を作れてしまう）。
module JitterHelper
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
  config.include JitterHelper
end
