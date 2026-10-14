# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Ak4Punch::TokenStore do
  describe ".load の保存ファイル境界" do
    let(:seed) { "dummy-seed" }
    let(:saved_token) { "dummy-token" }

    around do |example|
      Dir.mktmpdir do |dir|
        @load_path = File.join(dir, "token.json")
        example.run
      end
    end

    def expect_saved_token_error(hint)
      expect { described_class.load(path: @load_path, seed_token: seed) }.to raise_error(StandardError) do |error|
        expect(error.class.name).to eq "Ak4Punch::TokenStore::Error"
        expect(error.message).to include(hint)
        expect(error.message).not_to include(saved_token, seed)
        expect(error.full_message).not_to include(saved_token, seed)
        expect(error.cause).to be_nil
      end
    end

    it "正常な保存値と期限・閾値を読み、未知のキーは無視する" do
      expiry = t("09:30") + (10 * 86_400)
      File.write(@load_path, { token: saved_token, expired_at: Ak4Punch.format_akashi_time(expiry), extra: [1] }.to_json)

      store = described_class.load(path: @load_path, seed_token: seed, threshold_days: 15)

      expect(store.token).to eq saved_token
      expect(store.expired_at).to eq expiry
      expect(store.needs_refresh?(now: t("09:30"))).to be true
    end

    it "読み取り時点でENOENTならseedから初期化する" do
      File.write(@load_path, { token: saved_token }.to_json)
      allow(File).to receive(:read).with(@load_path).and_raise(Errno::ENOENT)

      store = described_class.load(path: @load_path, seed_token: seed)

      expect(store.token).to eq seed
      expect(store.expired_at).to be_nil
      expect(store.needs_refresh?).to be true
    end

    it "配列・null・整数・文字列のルートを明示的なErrorで拒否する" do
      aggregate_failures do
        [[], nil, 123, saved_token].each do |data|
          File.write(@load_path, data.to_json)
          expect_saved_token_error("JSON")
        end
      end
    end

    it "tokenの欠落・nil・空文字・非Stringを拒否する" do
      aggregate_failures do
        [{}, *[nil, "", 123, false, [], {}].map { |value| { token: value } }].each do |data|
          File.write(@load_path, data.to_json)
          expect_saved_token_error("token")
        end
      end
    end

    it "expired_atがnil以外の非Stringなら拒否する" do
      aggregate_failures do
        [123, false, [], {}].each do |value|
          File.write(@load_path, { token: saved_token, expired_at: value }.to_json)
          expect_saved_token_error("expired_at")
        end
      end
    end

    it "期限の欠落・nil・空文字・空白・パース不能は期限不明として受理しtokenを正規化しない" do
      aggregate_failures do
        [{}, *[nil, "", "  ", "not-a-date"].map { |value| { expired_at: value } }].each do |data|
          File.write(@load_path, data.merge(token: "  #{saved_token}  ").to_json)
          store = described_class.load(path: @load_path, seed_token: seed)

          expect(store.token).to eq "  #{saved_token}  "
          expect(store.expired_at).to be_nil
          expect(store.needs_refresh?).to be true
        end
        File.write(@load_path, { token: "  " }.to_json)
        expect(described_class.load(path: @load_path, seed_token: seed).token).to eq "  "
      end
    end

    it "壊れたJSONを拒否し、本文を例外本文やcauseへ載せない" do
      File.write(@load_path, %({"token":"#{saved_token}",))

      expect_saved_token_error("JSON::ParserError")
    end

    it "EACCES・EIOはseedへ戻らず停止し、元の例外messageを載せない" do
      File.write(@load_path, { token: saved_token }.to_json)
      aggregate_failures do
        [Errno::EACCES, Errno::EIO].each do |error_class|
          allow(File).to receive(:read).with(@load_path).and_raise(error_class, "#{saved_token} #{seed}")
          expect_saved_token_error(error_class.name)
        end
      end
    end
  end

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

  describe "再発行後の保存再試行" do
    let(:now) { t("09:30") }
    let(:expired_at) { now + (30 * 86_400) }
    let(:client) { Ak4Punch::Client.new(base_url: "https://example.invalid", company_id: "x", token: "seed") }

    it "保存が繰り返し失敗しても新tokenを保持し、API再発行なしで保存を完了する" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "token.json")
        store = described_class.new(path: path, token: "seed", expired_at: nil)
        allow(client).to receive(:reissue_token).and_return({ token: "new", expired_at: expired_at })
        attempts = 0
        allow(File).to receive(:rename).and_wrap_original do |rename, src, dst|
          attempts += 1
          raise Errno::EIO if attempts <= 2

          rename.call(src, dst)
        end

        2.times do
          expect { store.refresh!(client) }.to raise_error(Errno::EIO)
          expect(store.token).to eq "new"
          expect(store.expired_at).to eq expired_at
          expect(client.token).to eq "new"
          expect(store.needs_refresh?(now: now)).to be true
          expect(Dir.children(dir)).to be_empty
        end

        client.token = "stale"
        expect(store.refresh!(client)).to equal store
        expect(client.token).to eq "new"
        expect(client).to have_received(:reissue_token).once
        expect(store.needs_refresh?(now: now)).to be false
        loaded = described_class.load(path: path, seed_token: "seed")
        expect(loaded.token).to eq "new"
        expect(loaded.expired_at).to eq expired_at
        expect(File.stat(path).mode & 0o777).to eq 0o600
        expect(Dir.children(dir)).to eq ["token.json"]

        later = expired_at - (6 * 86_400)
        expect(store.needs_refresh?(now: later)).to be true
        next_expiry = later + (30 * 86_400)
        allow(client).to receive(:reissue_token).and_return({ token: "next", expired_at: next_expiry })
        store.refresh!(client)
        expect(client).to have_received(:reissue_token).twice
        expect(store.token).to eq "next"
        expect(client.token).to eq "next"
        expect(store.needs_refresh?(now: later)).to be false
        expect(described_class.load(path: path, seed_token: "seed").token).to eq "next"
      end
    end

    it "API再発行自体が失敗したときは、次回もAPIから更新する" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "token.json")
        store = described_class.new(path: path, token: "seed", expired_at: nil)
        allow(client).to receive(:reissue_token).and_raise(Ak4Punch::Client::ApiError, "unavailable")

        expect { store.refresh!(client) }.to raise_error(Ak4Punch::Client::ApiError)
        expect(store.token).to eq "seed"
        expect(client.token).to eq "seed"
        expect(store.needs_refresh?(now: now)).to be true
        expect(File.exist?(path)).to be false

        allow(client).to receive(:reissue_token).and_return({ token: "new", expired_at: expired_at })
        store.refresh!(client)

        expect(client).to have_received(:reissue_token).twice
        expect(described_class.load(path: path, seed_token: "seed").token).to eq "new"
        expect(store.needs_refresh?(now: now)).to be false
      end
    end

    it "persist! を直接成功させても保存待ちを解消する" do
      Dir.mktmpdir do |dir|
        store = described_class.new(path: File.join(dir, "token.json"), token: "seed", expired_at: nil)
        allow(client).to receive(:reissue_token).and_return({ token: "new", expired_at: expired_at })
        allow(File).to receive(:rename).and_raise(Errno::EIO)

        expect { store.refresh!(client) }.to raise_error(Errno::EIO)
        expect(store.needs_refresh?(now: now)).to be true
        allow(File).to receive(:rename).and_call_original
        store.persist!

        expect(store.needs_refresh?(now: now)).to be false
        store.refresh!(client)
        expect(client).to have_received(:reissue_token).twice
      end
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
