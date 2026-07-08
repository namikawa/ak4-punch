#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# Phase 0 検証スクリプト: 打刻API(6.6) の stampedAt 挙動確認（出勤/退勤ペア）
# -----------------------------------------------------------------------------
# 目的:
#   打刻API に stampedAt（指定した打刻日時）を付けて POST したとき、
#   実際に記録される打刻時刻が
#     ケースA) 指定した stampedAt になる       → 「22時に一括で固定時刻登録」が可能
#     ケースB) サーバ受信時刻（=実行した今）になる → 実時刻に2回起動する構成が必要
#   のどちらかを、打刻情報取得API(6.7) で突合して判定する。
#   出勤(type=11)/退勤(type=12) の2打刻を行い、それぞれ判定する。
#
# 依存: Ruby 標準ライブラリのみ（gem 不要）。
#
# 使い方:
#   1) .env に AK4_BASE_URL / AK4_COMPANY_ID / AK4_TOKEN を設定。
#   2) dry-run（送信せず内容確認）:
#        ruby scripts/verify_stamped_at.rb
#   3) 実際に打刻して検証（★実データが作られます / 既定 出勤09:30・退勤18:00）:
#        ruby scripts/verify_stamped_at.rb --execute
#
#   ※ 記録された打刻は、マイページ/管理画面の「打刻修正」で削除・修正できる前提。
# =============================================================================

require "net/http"
require "json"
require "uri"
require "optparse"
require "time"

JST = "+09:00"

# --- .env の簡易ローダ（dotenv gem を使わない） ------------------------------
def load_dotenv(path)
  return unless File.exist?(path)

  File.readlines(path).each do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#")

    key, sep, value = line.partition("=")
    next if sep.empty?

    ENV[key.strip] ||= value.strip.gsub(/\A["']|["']\z/, "")
  end
end

def blank?(value) = value.nil? || value.to_s.strip.empty?

def today_jst
  Time.now.getlocal(JST).to_date
end

def parse_jst(str)
  return nil if blank?(str)

  Time.strptime("#{str} +0900", "%Y/%m/%d %H:%M:%S %z")
rescue ArgumentError
  nil
end

load_dotenv(File.join(Dir.pwd, ".env"))

# --- オプション -------------------------------------------------------------
options = {
  base_url: ENV["AK4_BASE_URL"] || "https://atnd.ak4.jp/api/cooperation",
  company_id: ENV["AK4_COMPANY_ID"],
  token: ENV["AK4_TOKEN"],
  date: today_jst.strftime("%Y/%m/%d"),
  in_time: "09:30:00",
  out_time: "18:00:00",
  timezone: JST,
  only_in: false,
  execute: false,
}

OptionParser.new do |o|
  o.banner = "Usage: ruby scripts/verify_stamped_at.rb [options]"
  o.on("--base-url URL", "エンドポイントのベースURL") { |v| options[:base_url] = v }
  o.on("--company-id ID", "企業ID(login_company_code)") { |v| options[:company_id] = v }
  o.on("--token TOKEN", "アクセストークン") { |v| options[:token] = v }
  o.on("--date YYYY/MM/DD", "打刻対象日（既定: 本日 JST）") { |v| options[:date] = v }
  o.on("--in-time HH:MM:SS", "出勤の指定時刻") { |v| options[:in_time] = v }
  o.on("--out-time HH:MM:SS", "退勤の指定時刻") { |v| options[:out_time] = v }
  o.on("--timezone TZ", "タイムゾーン (例 +09:00)") { |v| options[:timezone] = v }
  o.on("--only-in", "出勤(type=11)のみ打刻する（退勤は行わない）") { options[:only_in] = true }
  o.on("--execute", "実際にPOSTする（未指定は dry-run）") { options[:execute] = true }
  o.on("-h", "--help") { puts o; exit 0 }
end.parse!

abort "エラー: 企業ID(AK4_COMPANY_ID)が未設定です（.env か --company-id で指定）。" if blank?(options[:company_id])
abort "エラー: トークン(AK4_TOKEN)が未設定です（.env か --token で指定）。" if blank?(options[:token])

STAMPED_IN  = "#{options[:date]} #{options[:in_time]}"
STAMPED_OUT = "#{options[:date]} #{options[:out_time]}"

# 打刻定義: [ラベル, type, stampedAt]
punches = [["出勤", 11, STAMPED_IN]]
punches << ["退勤", 12, STAMPED_OUT] unless options[:only_in]

# --- HTTP ヘルパ ------------------------------------------------------------
def request_json(method, url, body: nil)
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.open_timeout = 10
  http.read_timeout = 20

  req =
    case method
    when :get  then Net::HTTP::Get.new(uri)
    when :post then Net::HTTP::Post.new(uri)
    else raise ArgumentError, "unsupported method: #{method}"
    end

  if body
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)
  end

  res = http.request(req)
  parsed = (JSON.parse(res.body) rescue nil)
  [res.code.to_i, parsed, res.body]
end

def stamps_url(base, cid) = "#{base.chomp('/')}/#{cid}/stamps"

def get_day_stamps(base, cid, token, date_str)
  d = Date.strptime(date_str, "%Y/%m/%d")
  q = URI.encode_www_form(
    token: token,
    start_date: d.strftime("%Y%m%d000000"),
    end_date: d.strftime("%Y%m%d235959"),
  )
  request_json(:get, "#{stamps_url(base, cid)}?#{q}")
end

def fmt_stamps(json)
  stamps = json&.dig("response", "stamps") || []
  return "  (打刻なし)" if stamps.empty?

  stamps.map { |s| "  - type=#{s['type']} stamped_at=#{s['stamped_at']} local_time=#{s['local_time']}" }.join("\n")
end

def judge(label, requested_str, recorded_str, now_jst)
  requested = parse_jst(requested_str)
  recorded  = parse_jst(recorded_str)
  puts "  [#{label}] 指定=#{requested_str} / 記録=#{recorded_str || '(取得失敗)'}"
  return :unknown unless requested && recorded

  diff_req = (recorded - requested).abs
  diff_now = (recorded - now_jst).abs
  puts "        |記録-指定|=#{diff_req.round}s  |記録-now|=#{diff_now.round}s"
  if diff_req <= 90
    :case_a
  elsif diff_now <= 300
    :case_b
  else
    :unknown
  end
end

# --- 表示 -------------------------------------------------------------------
puts "=" * 70
puts "AKASHI 打刻API stampedAt 検証（出勤/退勤ペア）"
puts "=" * 70
puts "ベースURL : #{options[:base_url]}"
puts "企業ID    : #{options[:company_id]}"
puts "トークン  : #{options[:token].to_s[0, 4]}#{'*' * 8} (マスク表示)"
puts "対象日    : #{options[:date]}"
puts "出勤      : type=11  stampedAt=#{STAMPED_IN}"
puts "退勤      : type=12  stampedAt=#{STAMPED_OUT}"
puts "timezone  : #{options[:timezone]}"
puts "モード    : #{options[:execute] ? '★ 実行 (POST します)' : 'dry-run (送信しません)'}"
puts "-" * 70

puts "▼ 送信予定リクエスト:"
punches.each do |label, type, stamped_at|
  body = { token: "#{options[:token].to_s[0, 4]}********", type: type, stampedAt: stamped_at, timezone: options[:timezone] }
  puts "POST #{stamps_url(options[:base_url], options[:company_id])}  (#{label})"
  puts JSON.pretty_generate(body)
end
puts "-" * 70

unless options[:execute]
  puts "dry-run のため送信しません。実行するには --execute を付けてください。"
  exit 0
end

# --- 実行 -------------------------------------------------------------------
puts "▼ [1/3] 打刻前の当日打刻を取得 (GET)…"
code, before_json, = get_day_stamps(options[:base_url], options[:company_id], options[:token], options[:date])
puts "  HTTP #{code} success=#{before_json&.dig('success').inspect}"
puts fmt_stamps(before_json)
if before_json && before_json["success"] == false
  puts "  ! GET が success=false。errors=#{before_json['errors'].inspect}"
  puts "  （公開API利用可否/トークン/企業ID/ドメインを確認してください）"
  exit 1
end
puts "-" * 70

puts "▼ [2/3] 打刻を実行 (POST × #{punches.size})…"
recorded = {}
punches.each do |label, type, stamped_at|
  body = { token: options[:token], type: type, stampedAt: stamped_at, timezone: options[:timezone] }
  code, json, raw = request_json(:post, stamps_url(options[:base_url], options[:company_id]), body: body)
  puts "  (#{label}) HTTP #{code}  raw=#{raw}"
  if json && json["success"] == true
    recorded[type] = json.dig("response", "stampedAt")
    puts "    → サーバ側 stampedAt = #{recorded[type]}"
  else
    puts "    ! 打刻失敗。errors=#{json&.dig('errors').inspect}"
  end
end
puts "-" * 70

puts "▼ [3/3] 打刻後の当日打刻を再取得 (GET)…"
code, after_json, = get_day_stamps(options[:base_url], options[:company_id], options[:token], options[:date])
puts "  HTTP #{code}"
puts fmt_stamps(after_json)
puts "=" * 70

# --- 判定 -------------------------------------------------------------------
now_jst = Time.now.getlocal(JST)
puts "▼ 判定  (実行時刻 now=#{now_jst.strftime('%Y/%m/%d %H:%M:%S')})"
verdicts = punches.map do |label, type, stamped_at|
  judge(label, stamped_at, recorded[type], now_jst)
end
puts "-" * 70

if verdicts.all?(:case_a)
  puts "✅ ケースA: stampedAt が尊重されました（両打刻とも指定時刻で記録）。"
  puts "   → 「22時に一括で固定時刻登録」する当初案が使えます。"
elsif verdicts.all?(:case_b)
  puts "⚠️  ケースB: サーバ受信時刻で記録されました（stampedAt は無視）。"
  puts "   → 実際の出勤/退勤時刻に2回起動する構成へ切替が必要です（要相談）。"
else
  puts "❓ 混在/判定不能: #{verdicts.inspect}。上記の生データを確認してください。"
end

puts "=" * 70
puts "注意: この検証で作成された打刻は、マイページ/管理画面の「打刻修正」で削除・修正してください。"
