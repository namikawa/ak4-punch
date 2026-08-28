# frozen_string_literal: true

module Ak4Punch
  # イベントのタイトルをキーワードで判定する共通処理。
  # 出勤の除外（ClockInPlanner）・退勤の除外（ClockOutPlanner）・休暇（LeaveSchedule）は
  # 用途は違うが「タイトルにキーワードが含まれるか」という規則は同一なので、ここに集約する。
  #
  # 規則:
  #   - title が nil・空文字のイベントは決してキーワードに一致させない（＝業務イベント扱い）。
  #     タイトルの無いイベントを除外・休暇に倒すと、判定できないだけの予定で打刻目標が
  #     動いてしまうため、安全側（通常の業務イベントとして扱う）に倒す。
  #   - 一致は部分一致（include?）。時間の閾値などの追加条件は持たない。
  #
  # 空白のみのタイトル（" "）は「一致しない」ではなく通常の文字列として扱う（strip しない）。
  # Ak4Punch.blank? を使うと空白のみが nil と同じ扱いになり挙動が変わるので、ここでは使わない。
  module TitleKeywords
    module_function

    # 設定値のキーワード配列を正規化する（nil 可・文字列化・空文字は捨てる）。
    # 空文字を残すと String#include? が常に true になり、全イベントが一致してしまう。
    def normalize(keywords) = Array(keywords).map(&:to_s).reject(&:empty?)

    # title が keywords のいずれかに部分一致するか。keywords は normalize 済みを想定。
    def match?(title, keywords)
      return false if title.nil? || title.to_s.empty?

      keywords.any? { |kw| title.include?(kw) }
    end
  end
end
