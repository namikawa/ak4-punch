# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::CalendarClient do
  subject(:client) { described_class.new(base_url: "http://127.0.0.1:3000", api_key: "k" * 64) }

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

  it "JSON不正は ApiError" do
    stub_request(:get, %r{/events}).to_return(status: 200, body: "not json{")
    expect { client.events(date: date) }.to raise_error(Ak4Punch::CalendarClient::ApiError, /JSONパース/)
  end

  it "APIキー未設定なら通信せず ApiError" do
    no_key = described_class.new(base_url: "http://127.0.0.1:3000", api_key: nil)
    expect { no_key.events(date: date) }.to raise_error(Ak4Punch::CalendarClient::ApiError, /APIキー/)
  end
end
