# frozen_string_literal: true

require "date"
require "holiday_jp"

module Ak4Punch
  # 打刻対象日の判定。優先順位:
  #   1. extra_workdays に含まれる → 常に対象（週末/祝日でも出勤）
  #   2. exclude_dates に含まれる → 非対象
  #   3. 週末（weekdays_only 時）→ 非対象
  #   4. 日本の祝日（skip_japanese_holidays 時）→ 非対象
  #   5. それ以外 → 対象
  class WorkCalendar
    def initialize(weekdays_only: true, skip_japanese_holidays: true,
                   exclude_dates: [], extra_workdays: [])
      @weekdays_only = weekdays_only
      @skip_japanese_holidays = skip_japanese_holidays
      @exclude_dates = exclude_dates.to_a
      @extra_workdays = extra_workdays.to_a
    end

    def target?(date)
      reason(date).nil?
    end

    # 対象日なら nil、非対象ならスキップ理由(String)を返す。
    def reason(date)
      return nil if @extra_workdays.include?(date)
      return "除外日" if @exclude_dates.include?(date)
      return "週末" if @weekdays_only && weekend?(date)
      return "祝日" if @skip_japanese_holidays && HolidayJp.holiday?(date)

      nil
    end

    private

    def weekend?(date) = date.saturday? || date.sunday?
  end
end
