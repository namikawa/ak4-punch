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

  it "+09:00 以外のオフセット（海外タイムゾーンの招待）は JST に正規化する（瞬間は不変）" do
    stub_request(:get, %r{/events}).to_return(status: 200, body: {
      events: [{ id: "z", title: "UTC会議", ends_at: "2026-07-10T10:00:00+00:00", all_day: false }],
    }.to_json)

    ev = client.events(date: date).first
    expect(ev.ends_at.utc_offset).to eq 32_400
    expect(ev.ends_at).to eq Time.new(2026, 7, 10, 19, 0, 0, "+09:00")
  end

  it "JST正規化により日跨ぎの日付判定が JST 基準になる" do
    stub_request(:get, %r{/events}).to_return(status: 200, body: {
      events: [{ id: "z", title: "NY会議", starts_at: "2026-07-10T11:00:00-04:00",
                 ends_at: "2026-07-10T12:00:00-04:00", all_day: false }],
    }.to_json)

    ev = client.events(date: date).first
    # -04:00 の 7/10 12:00 は JST では 7/11 01:00。当日判定・表示ともに JST の日付で行う。
    expect(ev.ends_at.utc_offset).to eq 32_400
    expect(ev.ends_at.to_date).to eq Date.new(2026, 7, 11)
    expect(ev.ends_at.strftime("%Y-%m-%d %H:%M")).to eq "2026-07-11 01:00"
    expect(ev.starts_at).to eq Time.new(2026, 7, 11, 0, 0, 0, "+09:00")
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

  describe "レスポンスのスキーマ検証" do
    # HTTP 200 でも形が違う応答はある。黙って [] に潰すと「予定なし」の成功として扱われ、
    # 休暇情報が空で上書きされて休暇日の防御が外れる。要素が Hash でない場合は例外が
    # 定期再取得の経路を毎 tick 壊し、打刻が無通知のまま止まる。どちらも一過性ではないので
    # リトライしない ApiError にして、Daemon の既存の取得失敗経路に載せる。
    def stub_body(body)
      stub_request(:get, %r{/events}).to_return(status: 200, body: body)
    end

    it "events が null なら ApiError（「予定なし」として成功扱いにしない）" do
      stub_body({ date: "2026-07-10", events: nil }.to_json)
      expect { client.events(date: date) }
        .to raise_error(Ak4Punch::CalendarClient::ApiError, /応答の形式が不正です.*events が配列ではありません/)
    end

    it "events キーが無ければ ApiError" do
      stub_body({ date: "2026-07-10" }.to_json)
      expect { client.events(date: date) }
        .to raise_error(Ak4Punch::CalendarClient::ApiError, /応答の形式が不正です.*events がありません/)
    end

    it "events が配列でなければ ApiError（Hash が来た場合も TypeError にしない）" do
      stub_body({ events: { "id" => "x" } }.to_json)
      expect { client.events(date: date) }
        .to raise_error(Ak4Punch::CalendarClient::ApiError, /応答の形式が不正です.*events が配列ではありません/)
    end

    it "events の要素が Hash でなければ ApiError（NoMethodError にしない・位置が分かる）" do
      stub_body({ events: [{ id: "x" }, nil] }.to_json)
      expect { client.events(date: date) }
        .to raise_error(Ak4Punch::CalendarClient::ApiError,
                        /応答の形式が不正です.*events\[1\] がオブジェクトではありません/)
    end

    it "トップレベルが Hash でなければ ApiError" do
      stub_body([{ id: "x" }].to_json)
      expect { client.events(date: date) }
        .to raise_error(Ak4Punch::CalendarClient::ApiError, /応答の形式が不正です.*オブジェクトではありません/)
    end

    it "スキーマ不正はリトライしない（1回で ApiError・待機なし）" do
      stub = stub_body({ events: nil }.to_json)
      expect { client.events(date: date) }.to raise_error(Ak4Punch::CalendarClient::ApiError)
      expect(stub).to have_been_requested.times(1)
      expect(slept).to be_empty
    end

    it "巨大な応答でもエラーメッセージは切り詰める" do
      stub_body({ events: "x" * 5000 }.to_json)
      expect { client.events(date: date) }.to raise_error(Ak4Punch::CalendarClient::ApiError) { |e|
        expect(e.message.length).to be < 400
        expect(e.message).to end_with "…）"
      }
    end

    it "events が空配列なら「予定なし」として正常" do
      stub_body({ date: "2026-07-10", events: [] }.to_json)
      expect(client.events(date: date)).to eq []
    end

    describe "イベント内部のフィールドの型" do
      # 要素が Hash でも、下流が String / 真偽値 前提で扱うフィールドに別の型が来ると
      # Time.iso8601 の TypeError や include?/empty? の NoMethodError になり、
      # ApiError を通らないため定期再取得の経路が毎 tick 壊れる（打刻の無通知の飢餓）。
      it "starts_at が文字列でなければ ApiError（Time.iso8601 の TypeError にしない）" do
        stub_body({ events: [{ id: "x", starts_at: 1 }] }.to_json)
        expect { client.events(date: date) }
          .to raise_error(Ak4Punch::CalendarClient::ApiError,
                          /events\[0\]\.starts_at が文字列ではありません/)
      end

      it "ends_at が文字列でなければ ApiError（位置が分かる）" do
        stub_body({ events: [{ id: "a", ends_at: "2026-07-10T18:00:00+09:00" }, { id: "b", ends_at: 2 }] }.to_json)
        expect { client.events(date: date) }
          .to raise_error(Ak4Punch::CalendarClient::ApiError, /events\[1\]\.ends_at が文字列ではありません/)
      end

      it "title が文字列でなければ ApiError（休暇キーワード判定の NoMethodError にしない）" do
        stub_body({ events: [{ id: "x", title: 42 }] }.to_json)
        expect { client.events(date: date) }
          .to raise_error(Ak4Punch::CalendarClient::ApiError, /events\[0\]\.title が文字列ではありません/)
      end

      it "文字列でも日時として解析できなければ ApiError（黙って時刻なしのイベントにしない）" do
        # 従来は parse_time が ArgumentError を rescue して nil を返すため、このイベントが
        # 退勤の判定から落ちて基準が所定時刻へ巻き戻っていた（定期再取得で目標が前倒しされる）。
        stub_body({ events: [{ id: "x", title: "会議", ends_at: "oops" }] }.to_json)
        expect { client.events(date: date) }
          .to raise_error(Ak4Punch::CalendarClient::ApiError,
                          /events\[0\]\.ends_at が日時として解析できません/)
      end

      it "日付のみ（時刻なし）も ApiError（日時として解析できない）" do
        stub_body({ events: [{ id: "x", starts_at: "2026-07-10" }] }.to_json)
        expect { client.events(date: date) }
          .to raise_error(Ak4Punch::CalendarClient::ApiError, /events\[0\]\.starts_at が日時として解析できません/)
      end

      it "オフセットのない日時は ApiError（ホストのタイムゾーンで解釈させない）" do
        # Time.iso8601 はこの形式を受理してホストの TZ で解釈するため、解析可否では弾けない。
        # JST 基準の不変条件を守るには、境界でオフセットの存在まで要求する必要がある。
        stub_body({ events: [{ id: "x", title: "会議", ends_at: "2026-07-10T18:00:00" }] }.to_json)
        expect { client.events(date: date) }
          .to raise_error(Ak4Punch::CalendarClient::ApiError,
                          /events\[0\]\.ends_at にタイムゾーンオフセットがありません/)
      end

      it "Z・+0900・小数秒付きのオフセット表記は受理する" do
        stub_body({ events: [
          { id: "a", title: "UTC", ends_at: "2026-07-10T09:00:00Z", all_day: false },
          { id: "b", title: "コロンなし", ends_at: "2026-07-10T18:00:00+0900", all_day: false },
          { id: "c", title: "小数秒", ends_at: "2026-07-10T18:30:00.500+09:00", all_day: false },
        ] }.to_json)
        events = client.events(date: date)
        expect(events.map(&:id)).to eq %w[a b c]
        expect(events[0].ends_at).to eq Time.new(2026, 7, 10, 18, 0, 0, "+09:00") # JST 正規化
        expect(events[1].ends_at).to eq Time.new(2026, 7, 10, 18, 0, 0, "+09:00")
      end

      it "空文字・空白のみは「時刻なし」として正常（parse_time と同じ扱い）" do
        stub_body({ events: [{ id: "x", title: "会議", starts_at: "", ends_at: "  " }] }.to_json)
        ev = client.events(date: date).first
        expect(ev.starts_at).to be_nil
        expect(ev.ends_at).to be_nil
      end

      it "all_day が真偽値でなければ ApiError（終日を黙って通常イベント扱いにしない）" do
        stub_body({ events: [{ id: "x", all_day: "true" }] }.to_json)
        expect { client.events(date: date) }
          .to raise_error(Ak4Punch::CalendarClient::ApiError, /events\[0\]\.all_day が真偽値ではありません/)
      end

      it "title / starts_at / ends_at が nil、キー自体が無い場合は正常（実在の応答形）" do
        stub_body({ events: [
          { id: "def", title: nil, starts_at: nil, ends_at: nil, location: nil, all_day: true },
          { id: "z", location: "3F" }, # 時刻・タイトル・all_day のキーがない
        ] }.to_json)
        events = client.events(date: date)
        expect(events.size).to eq 2
        expect(events[0].all_day).to be true
        expect(events[1].starts_at).to be_nil
        expect(events[1].all_day).to be false
      end

      # location のように Event が保持しないキーは、型が何であっても素通りする
      # （実在の応答にはあるが本アプリでは使わないため、検証も保持もしない）。
      it "id の型は検証しない（数値で返る可能性がある）。使わないキーは型を問わず無視する" do
        stub_body({ events: [{ id: 12_345, title: "会議", location: 3,
                               ends_at: "2026-07-10T18:00:00+09:00", all_day: false }] }.to_json)
        ev = client.events(date: date).first
        expect(ev.id).to eq 12_345
        expect(ev.ends_at).to eq Time.new(2026, 7, 10, 18, 0, 0, "+09:00")
      end
    end
  end

  it "APIキー未設定なら通信せず ApiError" do
    no_key = described_class.new(base_url: "http://127.0.0.1:3000", api_key: nil)
    expect { no_key.events(date: date) }.to raise_error(Ak4Punch::CalendarClient::ApiError, /APIキー/)
  end

  # Net::HTTP に渡すホストは URI#hostname（角括弧なし）でなければならない。
  # WebMock は Net::HTTP#request をフックするので、URL ベースのスタブだけでは
  # URI#host（"[::1]"）を渡していても素通りしてしまい、この回帰を検出できない
  # （実機では Net::HTTP.new("[::1]", 3000) が getaddrinfo に失敗して Socket::ResolutionError になる）。
  # そのため Net::HTTP.new の第1引数を直接検証する。
  describe "Net::HTTP に渡すホスト" do
    it "IPv6 は角括弧を外した形を渡す（URI#host の \"[::1]\" では名前解決に失敗する）" do
      stub_request(:get, %r{/events}).to_return(status: 200, body: { events: [] }.to_json)
      ipv6 = described_class.new(base_url: "http://[::1]:3000", api_key: "k" * 64)

      expect(Net::HTTP).to receive(:new).with("::1", 3000).and_call_original
      expect(ipv6.events(date: date)).to eq []
    end

    it "通常のホスト（IPv4・ホスト名）では渡す値が変わらない" do
      stub_request(:get, %r{/events}).to_return(status: 200, body: { events: [] }.to_json)

      expect(Net::HTTP).to receive(:new).with("127.0.0.1", 3000).and_call_original
      expect(client.events(date: date)).to eq []
    end
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
