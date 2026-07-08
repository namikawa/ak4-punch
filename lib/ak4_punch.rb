# frozen_string_literal: true

require "time"
require "date"

module Ak4Punch
  # 日本標準時。AKASHI は打刻をサーバ受信時刻で記録するため、
  # 本アプリは「その時刻に呼び出す」前提で JST 基準の日付判定を行う。
  JST = "+09:00"

  module_function

  def now = Time.now.getlocal(JST)
  def today = now.to_date
end

require_relative "ak4_punch/version"
require_relative "ak4_punch/env_file"
require_relative "ak4_punch/config"
require_relative "ak4_punch/client"
require_relative "ak4_punch/token_store"
require_relative "ak4_punch/work_calendar"
require_relative "ak4_punch/stamper"
require_relative "ak4_punch/cli"
