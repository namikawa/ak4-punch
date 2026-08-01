# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ak4Punch::Client do
  subject(:client) do
    described_class.new(base_url: "https://atnd.ak4.jp/api/cooperation", company_id: "soldout", token: "tok")
  end

  it "post_stamp は正しいURL/bodyで叩き、記録時刻を返す" do
    stub = stub_request(:post, "https://atnd.ak4.jp/api/cooperation/soldout/stamps")
           .with(body: hash_including("token" => "tok", "type" => 11))
           .to_return(status: 200, body: {
             success: true,
             response: { login_company_code: "soldout", staff_id: 1, type: 11, stampedAt: "2026/07/08 09:30:01" },
           }.to_json)

    res = client.post_stamp(type: 11)
    expect(res[:stamped_at]).to eq "2026/07/08 09:30:01"
    expect(stub).to have_been_requested
  end

  it "success:false は ApiError を送出" do
    stub_request(:post, %r{/stamps\z})
      .to_return(status: 200, body: { success: false, errors: [{ code: "E", message: "だめ" }] }.to_json)

    expect { client.post_stamp(type: 11) }.to raise_error(Ak4Punch::Client::ApiError, /だめ/)
  end

  it "latest_stamp_type は stamped_at が最新の打刻種別を返す（日跨ぎ勤務対応）" do
    stub_request(:get, %r{/soldout/stamps})
      .to_return(status: 200, body: {
        success: true,
        response: { stamps: [
          { "type" => 12, "stamped_at" => "2026/07/08 01:21:25" }, # 前営業日の退勤（順不同で先頭）
          { "type" => 11, "stamped_at" => "2026/07/08 09:30:30" }, # 当日の出勤（最新）
        ] },
      }.to_json)

    expect(client.latest_stamp_type(date: Date.new(2026, 7, 8))).to eq 11
  end

  it "latest_stamp_type は打刻が無ければ nil" do
    stub_request(:get, %r{/soldout/stamps})
      .to_return(status: 200, body: { success: true, response: { stamps: [] } }.to_json)

    expect(client.latest_stamp_type(date: Date.new(2026, 7, 8))).to be_nil
  end

  it "reissue_token は新token/有効期限を返す" do
    stub_request(:post, "https://atnd.ak4.jp/api/cooperation/token/reissue/soldout")
      .to_return(status: 200, body: {
        success: true,
        response: { token: "new-token", expired_at: "2026/08/09 00:00:00" },
      }.to_json)

    result = client.reissue_token
    expect(result[:token]).to eq "new-token"
    expect(result[:expired_at]).to be_a(Time)
  end

  it "HTTP 500 は ApiError" do
    stub_request(:post, %r{/stamps\z}).to_return(status: 500, body: "oops")
    expect { client.post_stamp(type: 11) }.to raise_error(Ak4Punch::Client::ApiError, /HTTP 500/)
  end

  it "接続リセット(ECONNRESET)も ApiError にラップ" do
    stub_request(:post, %r{/stamps\z}).to_raise(Errno::ECONNRESET)
    expect { client.post_stamp(type: 11) }.to raise_error(Ak4Punch::Client::ApiError, /通信エラー/)
  end

  describe "打刻期限(deadline)の送信直前判定" do
    def at(hh, mm) = Time.new(2026, 7, 8, hh, mm, 0, "+09:00")

    let(:deadline) { at(9, 40) } # 目標09:30 + grace10分 相当

    # 接続確立の途中でスリープして復帰した状況は WebMock では再現できないため、
    # 「接続確立後に見た時刻」を注入 clock で表現して境界を検証する。
    def client_at(now)
      described_class.new(base_url: "https://atnd.ak4.jp/api/cooperation", company_id: "soldout",
                          token: "tok", clock: -> { now })
    end

    let(:success_body) do
      { success: true, response: { type: 11, stampedAt: "2026/07/08 09:30:01" } }.to_json
    end

    it "期限を過ぎていたら送信せずに中止する（HTTPリクエストが飛ばない）" do
      stub = stub_request(:post, %r{/stamps\z}).to_return(status: 200, body: success_body)

      expect { client_at(at(9, 45)).post_stamp(type: 11, deadline: deadline) }
        .to raise_error(Ak4Punch::DeadlineExceeded, /打刻期限を超過.*09:40:00.*09:45:00/)
      expect(stub).not_to have_been_requested
    end

    it "期限内なら従来どおり打刻する（境界の期限ちょうども送る）" do
      stub = stub_request(:post, %r{/stamps\z}).to_return(status: 200, body: success_body)

      res = client_at(at(9, 40)).post_stamp(type: 11, deadline: deadline)
      expect(res[:stamped_at]).to eq "2026/07/08 09:30:01"
      expect(stub).to have_been_requested
    end

    it "deadline 未指定なら期限判定せず送る（手動打刻は挙動不変）" do
      stub = stub_request(:post, %r{/stamps\z}).to_return(status: 200, body: success_body)

      res = client_at(at(23, 59)).post_stamp(type: 11) # 期限判定があれば必ず超過する時刻
      expect(res[:stamped_at]).to eq "2026/07/08 09:30:01"
      expect(stub).to have_been_requested
    end

    it "deadline 付きでも通信エラーは従来どおり ApiError にラップする" do
      stub_request(:post, %r{/stamps\z}).to_raise(Errno::ECONNRESET)

      expect { client_at(at(9, 35)).post_stamp(type: 11, deadline: deadline) }
        .to raise_error(Ak4Punch::Client::ApiError, /通信エラー/)
    end
  end
end
