# frozen_string_literal: true

require "time"
require "date"

module Ak4Punch
  # 日本標準時。AKASHI は打刻をサーバ受信時刻で記録するため、
  # 本アプリは「その時刻に呼び出す」前提で JST 基準の日付判定を行う。
  JST = "+09:00"

  # AKASHI が返す・token.json に保存する時刻の書式（タイムゾーンを持たないため JST として扱う）。
  AKASHI_TIME_FORMAT = "%Y/%m/%d %H:%M:%S"

  # 打刻種別の表示名。ログ・Slack通知・CLI 出力で共通に使う。
  KIND_LABELS = { in: "出勤", out: "退勤" }.freeze

  # 打刻期限（目標+grace）を過ぎたため打刻を中止した。
  # 打刻経路の複数の段（Stamper の冪等チェック後・Client の接続確立後）で送出するため、
  # モジュール直下に置いて共有する（下位の Client が上位の Stamper を参照しないように）。
  class DeadlineExceeded < StandardError; end

  module_function

  def now = Time.now.getlocal(JST)
  def today = now.to_date

  # AKASHI 形式の時刻文字列を Time にする。空文字・パース不能な値は nil を返す。
  def parse_akashi_time(str)
    return nil if str.nil? || str.to_s.strip.empty?

    Time.strptime("#{str} #{JST}", "#{AKASHI_TIME_FORMAT} %z")
  rescue ArgumentError
    nil
  end

  # Time を AKASHI 形式の文字列にする（nil はそのまま nil）。
  def format_akashi_time(time) = time&.strftime(AKASHI_TIME_FORMAT)
end

require_relative "ak4_punch/version"
require_relative "ak4_punch/env_file"
require_relative "ak4_punch/config"
require_relative "ak4_punch/client"
require_relative "ak4_punch/calendar_client"
require_relative "ak4_punch/token_store"
require_relative "ak4_punch/work_calendar"
require_relative "ak4_punch/clock_out_planner"
require_relative "ak4_punch/leave_detector"
require_relative "ak4_punch/wake_scheduler"
require_relative "ak4_punch/slack_notifier"
require_relative "ak4_punch/stamper"
require_relative "ak4_punch/daemon"
require_relative "ak4_punch/cli"
