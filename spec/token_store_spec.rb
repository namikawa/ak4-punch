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

  describe "#persist!（atomic write）" do
    it "所有者のみ読み書き可(0600)の正しいJSONを書く" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "token.json")
        described_class.new(path: path, token: "t", expired_at: Time.new(2026, 8, 31, 0, 0, 0, "+09:00")).persist!

        expect(File.stat(path).mode & 0o777).to eq 0o600
        expect(JSON.parse(File.read(path)))
          .to eq("token" => "t", "expired_at" => "2026/08/31 00:00:00")
        expect(Dir.children(dir)).to eq ["token.json"] # 一時ファイルは残らない
      end
    end

    it "一時ファイル名はプロセス毎に分ける（並行する別プロセスの保存と踏み合わない）" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "token.json")
        renamed = []
        allow(File).to receive(:rename) { |src, dst| renamed << [src, dst] } # 置き換えの引数を観察する

        described_class.new(path: path, token: "t", expired_at: Time.now).persist!

        expect(renamed).to eq [["#{path}.tmp.#{Process.pid}", path]]
        expect(Dir.children(dir)).to be_empty # 一時ファイルは後始末される
      end
    end

    it "置き換えに失敗しても既存の token.json は壊れない" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "token.json")
        File.write(path, JSON.pretty_generate("token" => "old", "expired_at" => "2026/08/01 00:00:00"))
        allow(File).to receive(:rename).and_raise(Errno::EIO)

        store = described_class.new(path: path, token: "new", expired_at: Time.now)
        expect { store.persist! }.to raise_error(Errno::EIO)
        expect(JSON.parse(File.read(path))["token"]).to eq "old"
        expect(Dir.children(dir)).to eq ["token.json"] # 書きかけの一時ファイルも残らない
      end
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
