# frozen_string_literal: true

require "webmock/rspec"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ak4_punch"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |m| m.verify_partial_doubles = true }
  config.disable_monkey_patching!
end
