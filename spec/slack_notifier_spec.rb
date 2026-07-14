# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::SlackNotifier do
  let(:url) { "https://hooks.slack.com/services/T000/B000/XXXX" }
  let(:logger) { instance_double(Logger, warn: nil) }
  subject(:notifier) { described_class.new(webhook_url: url, logger: logger) }

  it "正常: [ak4-punch] プレフィックス付きの text を JSON POST する" do
    stub = stub_request(:post, url)
           .with(
             headers: { "Content-Type" => "application/json" },
             body: { text: "[ak4-punch] 打刻に失敗しました" }.to_json,
           )
           .to_return(status: 200, body: "ok")

    notifier.notify("打刻に失敗しました")
    expect(stub).to have_been_requested
    expect(logger).not_to have_received(:warn)
  end

  it "非2xx は警告ログのみで例外を上げない" do
    stub_request(:post, url).to_return(status: 404, body: "no_service")

    expect { notifier.notify("x") }.not_to raise_error
    expect(logger).to have_received(:warn).with(/Slack通知に失敗.*404/)
  end

  it "通信エラー（接続拒否）は警告ログのみで例外を上げない" do
    stub_request(:post, url).to_raise(Errno::ECONNREFUSED)

    expect { notifier.notify("x") }.not_to raise_error
    expect(logger).to have_received(:warn).with(/Slack通知に失敗/)
  end

  it "タイムアウトも警告ログのみで例外を上げない" do
    stub_request(:post, url).to_timeout

    expect { notifier.notify("x") }.not_to raise_error
    expect(logger).to have_received(:warn).with(/Slack通知に失敗/)
  end

  it "URL 未設定なら完全に no-op（リクエストもログも出ない）" do
    off = described_class.new(webhook_url: nil, logger: logger)
    expect(off.enabled?).to be false

    off.notify("x") # WebMock がネットワーク遮断中: リクエストすれば warn が出るはず
    expect(logger).not_to have_received(:warn)
  end

  it "URL が空文字でも no-op" do
    off = described_class.new(webhook_url: "", logger: logger)
    expect(off.enabled?).to be false
    off.notify("x")
    expect(logger).not_to have_received(:warn)
  end

  describe "保持・再送（pending）" do
    it "送信失敗したメッセージは保持され、retry_pending で成功したらキューが空になり INFO を出す" do
      logger2 = instance_double(Logger, warn: nil, info: nil)
      n = described_class.new(webhook_url: url, logger: logger2)

      stub_request(:post, url).to_return(status: 500) # notify 時は失敗
      n.notify("失敗メッセージ")
      expect(logger2).to have_received(:warn).with(/Slack通知に失敗.*保留/).once

      # 再送は成功させる
      WebMock.reset!
      ok = stub_request(:post, url)
           .with(body: { text: "[ak4-punch] 失敗メッセージ" }.to_json)
           .to_return(status: 200, body: "ok")
      n.retry_pending
      expect(ok).to have_been_requested
      expect(logger2).to have_received(:info).with(/保留していた通知を再送しました/).once

      # キューは空: 再度 retry_pending してもリクエストは出ない
      WebMock.reset!
      again = stub_request(:post, url).to_return(status: 200)
      n.retry_pending
      expect(again).not_to have_been_requested
    end

    it "retry_pending の再失敗はキューに残し、warn を出さない（ログスパム防止）" do
      logger2 = instance_double(Logger, warn: nil, info: nil)
      n = described_class.new(webhook_url: url, logger: logger2)

      stub_request(:post, url).to_return(status: 500)
      n.notify("x") # 初回失敗 → warn 1回
      expect(logger2).to have_received(:warn).once

      n.retry_pending # 再失敗 → warn 増えない・INFO なし
      expect(logger2).to have_received(:warn).once
      expect(logger2).not_to have_received(:info)

      # まだキューに残っているので、成功させれば再送される
      WebMock.reset!
      ok = stub_request(:post, url).to_return(status: 200)
      n.retry_pending
      expect(ok).to have_been_requested
    end

    it "初回失敗時のみ warn（notify）で、retry_pending 側は warn を出さない" do
      logger2 = instance_double(Logger, warn: nil, info: nil)
      n = described_class.new(webhook_url: url, logger: logger2)

      stub_request(:post, url).to_timeout
      n.notify("x")
      n.retry_pending
      n.retry_pending
      expect(logger2).to have_received(:warn).once
    end

    it "上限10件を超えると古いものから破棄し、警告を出す" do
      logger2 = instance_double(Logger, warn: nil, info: nil)
      n = described_class.new(webhook_url: url, logger: logger2)

      stub_request(:post, url).to_return(status: 500) # 全て失敗
      12.times { |i| n.notify("msg#{i}") }
      # 12件送って上限10件 → 古い2件（msg0, msg1）が破棄され警告が2回出る
      expect(logger2).to have_received(:warn).with(/保留中の通知が上限（10件）を超えた/).twice

      # 再送は成功させ、送られた本文を検証（残るのは msg2〜msg11 の10件で、順序も保たれる）
      WebMock.reset!
      sent = []
      stub_request(:post, url).to_return(status: 200).with do |req|
        sent << JSON.parse(req.body)["text"]
        true
      end
      n.retry_pending
      expect(sent).to eq((2..11).map { |i| "[ak4-punch] msg#{i}" })
    end

    it "URL 未設定なら notify も retry_pending も no-op（リクエストもログも出ない）" do
      off = described_class.new(webhook_url: nil, logger: logger)
      off.notify("x")
      off.retry_pending
      expect(logger).not_to have_received(:warn)
    end
  end

  describe "メンション" do
    it "mention 指定時はメンションを先頭に付けて送信する" do
      stub = stub_request(:post, url)
             .with(body: { text: "<@U04XXXXXX> [ak4-punch] 打刻に失敗しました" }.to_json)
             .to_return(status: 200, body: "ok")

      with_mention = described_class.new(webhook_url: url, mention: "<@U04XXXXXX>", logger: logger)
      with_mention.notify("打刻に失敗しました")
      expect(stub).to have_been_requested
    end

    it "mention が nil/空文字なら従来どおりメンションなし" do
      stub = stub_request(:post, url)
             .with(body: { text: "[ak4-punch] x" }.to_json)
             .to_return(status: 200, body: "ok")

      described_class.new(webhook_url: url, mention: "", logger: logger).notify("x")
      expect(stub).to have_been_requested
    end

    it "mention の前後空白は取り除かれる" do
      stub = stub_request(:post, url)
             .with(body: { text: "<@U04XXXXXX> [ak4-punch] x" }.to_json)
             .to_return(status: 200, body: "ok")

      described_class.new(webhook_url: url, mention: " <@U04XXXXXX> ", logger: logger).notify("x")
      expect(stub).to have_been_requested
    end

    it "素のメンバーID（U...）は <@ID> 形式に自動整形する" do
      stub = stub_request(:post, url)
             .with(body: { text: "<@U04XXXXXX> [ak4-punch] x" }.to_json)
             .to_return(status: 200, body: "ok")

      described_class.new(webhook_url: url, mention: "U04XXXXXX", logger: logger).notify("x")
      expect(stub).to have_been_requested
    end

    it "@付きの素のID（@U...）も <@ID> 形式に自動整形する" do
      stub = stub_request(:post, url)
             .with(body: { text: "<@U04XXXXXX> [ak4-punch] x" }.to_json)
             .to_return(status: 200, body: "ok")

      described_class.new(webhook_url: url, mention: "@U04XXXXXX", logger: logger).notify("x")
      expect(stub).to have_been_requested
    end

    it "<!channel> のような特殊メンションはそのまま使う" do
      stub = stub_request(:post, url)
             .with(body: { text: "<!channel> [ak4-punch] x" }.to_json)
             .to_return(status: 200, body: "ok")

      described_class.new(webhook_url: url, mention: "<!channel>", logger: logger).notify("x")
      expect(stub).to have_been_requested
    end
  end
end
