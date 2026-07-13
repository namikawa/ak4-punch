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
end
