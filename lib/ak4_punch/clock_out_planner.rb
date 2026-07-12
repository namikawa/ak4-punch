# frozen_string_literal: true

require "date"

module Ak4Punch
  # カレンダーのイベント配列から退勤の目標時刻を決める純ロジック。
  #
  # 手順:
  #   1. 対象イベント = all_day:false かつ ends_at 非null かつ ends_at の日付が当日、のみ
  #      （日跨ぎイベントは対象外）
  #   2. ends_at 昇順に並べ、末尾から exclude_keywords に部分一致するタイトルの間スキップ、
  #      最初の非除外イベントの ends_at を候補とする（title が nil は除外対象にしない＝業務扱い）
  #   3. 目標 = max(所定退勤時刻, 候補)。候補なし（全除外/イベントなし）なら所定時刻。
  #
  # 戻り値 Plan は判断根拠（採用イベント/除外イベント/フォールバック理由）を持ち、
  # `punch plan` やログで説明できるようにする。
  class ClockOutPlanner
    # target_at: 決定した退勤目標時刻(Time)
    # source: :calendar（イベント採用） / :default（所定時刻フォールバック）
    # adopted_event: 採用したイベント（Event or nil）
    # excluded_events: 末尾でスキップした除外イベント配列（新しい順）
    # considered_events: 判定対象になった当日イベント（ends_at 昇順）
    # fallback_reason: フォールバックした理由（String or nil）
    Plan = Struct.new(
      :target_at, :source, :adopted_event, :excluded_events, :considered_events, :fallback_reason,
      keyword_init: true,
    )

    def initialize(exclude_keywords:)
      @exclude_keywords = Array(exclude_keywords).map(&:to_s).reject(&:empty?)
    end

    # events: CalendarClient::Event 配列
    # date: 判定対象日(Date)
    # default_clock_out: 所定退勤時刻(Time) — max の下限かつフォールバック先
    def plan(events:, date:, default_clock_out:)
      considered = target_events(events, date).sort_by(&:ends_at)

      if considered.empty?
        return fallback(default_clock_out, considered, [], "対象となる業務イベントがありません")
      end

      excluded = []
      adopted = nil
      considered.reverse_each do |ev|
        if excluded_by_keyword?(ev)
          excluded << ev
          next
        end
        adopted = ev
        break
      end

      if adopted.nil?
        return fallback(default_clock_out, considered, excluded,
                        "末尾の業務イベントが全て除外キーワードに一致しました")
      end

      target = [default_clock_out, adopted.ends_at].max
      Plan.new(
        target_at: target,
        source: :calendar,
        adopted_event: adopted,
        excluded_events: excluded,
        considered_events: considered,
        fallback_reason: (target == default_clock_out ? "採用イベントが所定退勤時刻より早いため所定時刻を採用" : nil),
      )
    end

    private

    def fallback(default_clock_out, considered, excluded, reason)
      Plan.new(
        target_at: default_clock_out,
        source: :default,
        adopted_event: nil,
        excluded_events: excluded,
        considered_events: considered,
        fallback_reason: reason,
      )
    end

    # 対象: all_day:false かつ ends_at 非null かつ ends_at の日付が当日。
    def target_events(events, date)
      Array(events).select do |ev|
        !ev.all_day && !ev.ends_at.nil? && ev.ends_at.to_date == date
      end
    end

    # title が nil のイベントは除外しない（業務扱い）。部分一致で判定。
    def excluded_by_keyword?(event)
      title = event.title
      return false if title.nil? || title.to_s.empty?

      @exclude_keywords.any? { |kw| title.include?(kw) }
    end
  end
end
