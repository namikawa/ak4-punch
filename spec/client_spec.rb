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
end
