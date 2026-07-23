# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::CalendarClient do
  # 待機は記録するだけ（実 sleep しない）。リトライのバックオフ検証にも使う。
  let(:slept) { [] }
  subject(:client) do
    described_class.new(base_url: "http://127.0.0.1:3000", api_key: "k" * 64, sleeper: ->(s) { slept << s })
  end

  let(:events_url) { "http://127.0.0.1:3000/api/v1/calendars/google/events" }
  let(:date) { Date.new(2026, 7, 10) }

  it "正常: イベント配列を Event に変換し、Bearer 認証で叩く" do
    stub = stub_request(:get, "#{events_url}?date=2026-07-10")
           .with(headers: { "Authorization" => "Bearer #{'k' * 64}" })
           .to_return(status: 200, body: {
             date: "2026-07-10",
             events: [
               {
                 id: "abc", title: "打合せ", location: "3F",
                 starts_at: "2026-07-10T13:00:00+09:00", ends_at: "2026-07-10T19:30:00+09:00", all_day: false,
               },
               { id: "def", title: nil, starts_at: nil, ends_at: nil, location: nil, all_day: true },
             ],
           }.to_json)

    events = client.events(date: date)
    expect(stub).to have_been_requested
    expect(events.size).to eq 2
    first = events.first
    expect(first.id).to eq "abc"
    expect(first.title).to eq "打合せ"
    expect(first.all_day).to be false
    expect(first.ends_at).to eq Time.new(2026, 7, 10, 19, 30, 0, "+09:00")
    expect(events[1].all_day).to be true
    expect(events[1].ends_at).to be_nil
  end

  it "オフセットは文字列の値を信頼する（+09:00決め打ちにしない）" do
    stub_request(:get, %r{/events}).to_return(status: 200, body: {
      events: [{ id: "z", title: "UTC会議", ends_at: "2026-07-10T10:00:00+00:00", all_day: false }],
    }.to_json)

    ev = client.events(date: date).first
    expect(ev.ends_at.utc_offset).to eq 0
  end

  it "401 は ApiError（error.message を含む）" do
    stub_request(:get, %r{/events}).to_return(status: 401, body: {
      error: { code: "unauthorized", message: "認証に失敗しました" },
    }.to_json)

    expect { client.events(date: date) }.to raise_error(Ak4Punch::CalendarClient::ApiError, /401.*認証/)
  end

  it "503 provider_not_connected は ApiError" do
    stub_request(:get, %r{/events}).to_return(status: 503, body: {
      error: { code: "provider_not_connected", message: "未接続" },
    }.to_json)

    expect { client.events(date: date) }.to raise_error(Ak4Punch::CalendarClient::ApiError, /503/)
  end

  it "接続拒否(ECONNREFUSED)は ApiError にラップ" do
    stub_request(:get, %r{/events}).to_raise(Errno::ECONNREFUSED)
    expect { client.events(date: date) }.to raise_error(Ak4Punch::CalendarClient::ApiError, /通信エラー/)
  end

  it "接続リセット(ECONNRESET)も ApiError にラップ" do
    stub_request(:get, %r{/events}).to_raise(Errno::ECONNRESET)
    expect { client.events(date: date) }.to raise_error(Ak4Punch::CalendarClient::ApiError, /通信エラー/)
  end

  it "JSON不正は ApiError" do
    stub_request(:get, %r{/events}).to_return(status: 200, body: "not json{")
    expect { client.events(date: date) }.to raise_error(Ak4Punch::CalendarClient::ApiError, /JSONパース/)
  end

  it "APIキー未設定なら通信せず ApiError" do
    no_key = described_class.new(base_url: "http://127.0.0.1:3000", api_key: nil)
    expect { no_key.events(date: date) }.to raise_error(Ak4Punch::CalendarClient::ApiError, /APIキー/)
  end

  describe "一過性エラーのリトライ" do
    it "5xx はリトライし、回復すれば成功する" do
      stub = stub_request(:get, %r{/events}).to_return(
        { status: 503, body: { error: { code: "provider_not_connected", message: "未接続" } }.to_json },
        { status: 200, body: { events: [{ id: "x", title: "会議", ends_at: "2026-07-10T18:00:00+09:00" }] }.to_json },
      )

      events = client.events(date: date)
      expect(events.size).to eq 1
      expect(stub).to have_been_requested.twice
      expect(slept).to eq [2] # 1回リトライで成功
    end

    it "5xx が続けばリトライを使い切って ApiError（計3回試行・バックオフ 2→4秒）" do
      stub = stub_request(:get, %r{/events}).to_return(status: 503, body: { error: { message: "未接続" } }.to_json)

      expect { client.events(date: date) }.to raise_error(Ak4Punch::CalendarClient::ApiError, /503/)
      expect(stub).to have_been_requested.times(3)
      expect(slept).to eq [2, 4]
    end

    it "通信エラーもリトライ対象（使い切ったら ApiError）" do
      stub = stub_request(:get, %r{/events}).to_raise(Errno::ECONNREFUSED)

      expect { client.events(date: date) }.to raise_error(Ak4Punch::CalendarClient::ApiError, /通信エラー/)
      expect(stub).to have_been_requested.times(3)
      expect(slept).to eq [2, 4]
    end

    it "Net::HTTP の内蔵リトライ(max_retries)を無効化して二重リトライを防ぐ" do
      response = instance_double(Net::HTTPResponse, code: "200", body: { events: [] }.to_json)
      http = instance_spy(Net::HTTP)
      allow(http).to receive(:request).and_return(response)
      allow(Net::HTTP).to receive(:new).and_return(http)

      client.events(date: date)

      expect(http).to have_received(:max_retries=).with(0)
    end

    it "4xx はリトライしない（1回で ApiError・待機なし）" do
      stub = stub_request(:get, %r{/events})
             .to_return(status: 401, body: { error: { message: "認証に失敗しました" } }.to_json)

      expect { client.events(date: date) }.to raise_error(Ak4Punch::CalendarClient::ApiError, /401/)
      expect(stub).to have_been_requested.times(1)
      expect(slept).to be_empty
    end
  end
end
