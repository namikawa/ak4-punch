# frozen_string_literal: true

module Ak4Punch
  # カレンダーのイベントから「休暇」を検知する純ロジック。
  # AKASHI は休暇申請日でも打刻を受理する（実機確認済み）ため、
  # カレンダー上の休暇イベントの検知が、休暇日の誤打刻を防ぐ主手段になる。
  #
  # 判定条件（両方を満たすイベントが1件でもあれば休暇日）:
  #   1. タイトルが leave_keywords に部分一致（title が nil のイベントは非該当）
  #   2. 「all_day: true（終日）」または
  #      「starts_at/ends_at 両方非nil かつ継続時間が min_duration_hours 以上」
  #
  # 継続時間の閾値は、短時間（例: 2時間）の「XX休み」のような中抜けイベントを
  # 休暇と誤検知しないためのもの。終日イベントは長さの概念がないため無条件で該当。
  class LeaveDetector
    def initialize(keywords:, min_duration_hours:)
      @keywords = Array(keywords).map(&:to_s).reject(&:empty?)
      @min_duration_seconds = min_duration_hours * 3600
    end

    # イベント配列から最初に見つかった休暇イベントを返す（なければ nil）。
    # 判定対象はその日の全イベント（時間帯・並び順は問わない）。
    def detect(events)
      Array(events).find { |ev| leave?(ev) }
    end

    private

    def leave?(event)
      title = event.title
      return false if title.nil? || title.to_s.empty?
      return false unless @keywords.any? { |kw| title.include?(kw) }

      return true if event.all_day # 終日は無条件で休暇扱い

      # 時間指定イベントは閾値以上の長さのときのみ休暇扱い（中抜けの誤検知防止）。
      return false if event.starts_at.nil? || event.ends_at.nil?

      (event.ends_at - event.starts_at) >= @min_duration_seconds
    end
  end
end
