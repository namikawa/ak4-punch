# frozen_string_literal: true

require "spec_helper"

# 接続オブジェクトを組み立てるだけなので通信は発生しない（WebMock のスタブは不要）。
RSpec.describe Ak4Punch::Http do
  # Net::HTTP に渡すホストは URI#hostname（角括弧なし）でなければならない。
  # URI#host は IPv6 を "[::1]" と返し、実機では Net::HTTP.new("[::1]", 3000) が
  # getaddrinfo に失敗して Socket::ResolutionError になる（sukesan のループバック運用で踏む）。
  # Net::HTTP#address には渡した値がそのまま入るので、ここで直接検証する。
  describe "ホストの受け渡し" do
    it "IPv6 は角括弧を外した形を渡す（URI#host の \"[::1]\" では名前解決に失敗する）" do
      http = described_class.build(URI("http://[::1]:3000/x"), open_timeout: 5, read_timeout: 5)

      expect(http.address).to eq "::1"
      expect(http.port).to eq 3000
    end

    it "通常のホスト（IPv4・ホスト名）では渡す値が変わらない" do
      expect(described_class.build(URI("http://127.0.0.1:3000/x"), open_timeout: 5, read_timeout: 5).address)
        .to eq "127.0.0.1"
      expect(described_class.build(URI("https://example.com/x"), open_timeout: 5, read_timeout: 5).address)
        .to eq "example.com"
    end
  end

  describe "use_ssl" do
    it "https なら有効" do
      http = described_class.build(URI("https://atnd.ak4.jp/api/x"), open_timeout: 5, read_timeout: 5)

      expect(http.use_ssl?).to be true
      expect(http.port).to eq 443
    end

    it "http なら無効（ループバックの sukesan は http で運用する）" do
      http = described_class.build(URI("http://127.0.0.1:3000/x"), open_timeout: 5, read_timeout: 5)

      expect(http.use_ssl?).to be false
    end
  end

  it "タイムアウトは渡した値がそのまま入る（用途ごとに異なるため呼び出し側が決める）" do
    http = described_class.build(URI("https://example.com/x"), open_timeout: 10, read_timeout: 20)

    expect(http.open_timeout).to eq 10
    expect(http.read_timeout).to eq 20
  end
end
