# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Ak4Punch::TokenStore do
  it "token.json が無ければ seed から生成し、有効期限不明なら要再発行" do
    Dir.mktmpdir do |dir|
      store = described_class.load(path: File.join(dir, "token.json"), seed_token: "seed")
      expect(store.token).to eq "seed"
      expect(store.needs_refresh?).to be true
    end
  end

  it "有効期限が十分先なら再発行不要" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "token.json")
      File.write(path, { token: "t", expired_at: (Date.today + 30).strftime("%Y/%m/%d 00:00:00") }.to_json)
      store = described_class.load(path: path, seed_token: nil, threshold_days: 7)
      expect(store.needs_refresh?).to be false
    end
  end

  it "有効期限が閾値以内なら要再発行" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "token.json")
      File.write(path, { token: "t", expired_at: (Date.today + 3).strftime("%Y/%m/%d 00:00:00") }.to_json)
      store = described_class.load(path: path, seed_token: nil, threshold_days: 7)
      expect(store.needs_refresh?).to be true
    end
  end

  it "refresh! で新tokenを取得し token.json に保存する" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "token.json")
      store = described_class.load(path: path, seed_token: "seed")

      client = instance_double(Ak4Punch::Client)
      allow(client).to receive(:token=)
      allow(client).to receive(:reissue_token).and_return({ token: "new", expired_at: Time.now + (30 * 86_400) })

      store.refresh!(client)

      expect(store.token).to eq "new"
      expect(JSON.parse(File.read(path))["token"]).to eq "new"
    end
  end

  it "再発行結果が空トークンなら例外" do
    Dir.mktmpdir do |dir|
      store = described_class.load(path: File.join(dir, "token.json"), seed_token: "seed")
      client = instance_double(Ak4Punch::Client)
      allow(client).to receive(:token=)
      allow(client).to receive(:reissue_token).and_return({ token: nil, expired_at: nil })
      expect { store.refresh!(client) }.to raise_error(/再発行に失敗/)
    end
  end
end
