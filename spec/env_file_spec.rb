# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Ak4Punch::EnvFile do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  def write_env(content)
    path = File.join(@dir, ".env")
    File.write(path, content)
    path
  end

  it "日本語コメントを含む .env を US-ASCII ロケール（cron相当）でも壊れず読める" do
    path = write_env(<<~ENV)
      # 企業ID（日本語コメント：バイト列に注意）
      AK4_TEST_COMPANY='soldout'
      # アクセストークン（有効期限「1ヶ月と1日」）
      AK4_TEST_TOKEN="abc-123"
    ENV

    original = Encoding.default_external
    begin
      Encoding.default_external = Encoding::US_ASCII
      expect { described_class.load(path) }.not_to raise_error
      expect(ENV.fetch("AK4_TEST_COMPANY")).to eq "soldout"
      expect(ENV.fetch("AK4_TEST_TOKEN")).to eq "abc-123"
    ensure
      Encoding.default_external = original
      ENV.delete("AK4_TEST_COMPANY")
      ENV.delete("AK4_TEST_TOKEN")
    end
  end

  it "既存の環境変数は上書きしない" do
    path = write_env("AK4_TEST_EXISTING=fromfile\n")
    ENV["AK4_TEST_EXISTING"] = "preset"
    begin
      described_class.load(path)
      expect(ENV.fetch("AK4_TEST_EXISTING")).to eq "preset"
    ensure
      ENV.delete("AK4_TEST_EXISTING")
    end
  end
end
