# frozen_string_literal: true

require "date"

module Ak4Punch
  # カレンダーのイベント配列から出勤の「打刻締切」を決める純ロジック（ClockOutPlanner の鏡像）。
  # 退勤が「最後の業務イベントの終了に合わせて遅らせる」のに対し、
  # 出勤は「最初の業務イベントの開始までに済ませる」ため、締切（上限）を返す。
  #
  # 手順:
  #   1. 対象イベント = all_day:false かつ starts_at 非null かつ starts_at の日付が当日、のみ
  #      （前日から続く日跨ぎイベントは対象外）
  #   2. earliest_at（下限）が指定されていれば、それより前に始まるイベントを対象から外す
  #      （Mac がスリープ中で物理的に間に合わない時刻をアンカーにしないため。
  #        深夜イベントで日付変更直後に打刻してしまう事故も防ぐ）
  #   3. starts_at 昇順に並べ、先頭から exclude_keywords に部分一致するタイトルの間スキップ、
  #      最初の非除外イベントの starts_at を候補とする（title が nil は除外対象にしない＝業務扱い）
  #      ※1件だけでなく連続してスキップする（移動 8:00 → 私用 8:30 → 会議 9:00 で会議を採用する）
  #   4. 締切 = min(所定の出勤締切, 候補)。候補なし（全除外/イベントなし）なら所定の締切。
  #
  # 戻り値 Plan は判断根拠（採用イベント/除外イベント/フォールバック理由）を持ち、
  # `punch plan` やログで説明できるようにする。
  class ClockInPlanner
    # deadline_at: 決定した出勤の打刻締切(Time)
    # source: :calendar（イベント採用） / :default（所定の締切へフォールバック）
    # adopted_event: 採用したイベント（Event or nil）
    # excluded_events: 先頭でスキップした除外イベント配列（早い順）
    # too_early_events: earliest_at より前に始まるため対象外にしたイベント配列（早い順）
    # considered_events: 判定対象になった当日イベント（starts_at 昇順・too_early は含まない）
    # fallback_reason: フォールバックした理由（String or nil）
    Plan = Struct.new(
      :deadline_at, :source, :adopted_event, :excluded_events, :too_early_events,
      :considered_events, :fallback_reason,
      keyword_init: true,
    )

    def initialize(exclude_keywords:)
      @exclude_keywords = Array(exclude_keywords).map(&:to_s).reject(&:empty?)
    end

    # events: CalendarClient::Event 配列
    # date: 判定対象日(Date)
    # default_deadline: 所定の出勤締切(Time) — min の上限かつフォールバック先
    # earliest_at: 採用する開始時刻の下限(Time or nil)。nil なら下限なし。
    def plan(events:, date:, default_deadline:, earliest_at: nil)
      all = target_events(events, date).sort_by(&:starts_at)
      too_early, considered =
        earliest_at ? all.partition { |ev| ev.starts_at < earliest_at } : [[], all]

      if considered.empty?
        # 「イベント自体がない」と「あったが全て下限より前」を区別する（`punch plan` の
        # イベント一覧に [早すぎ] と出るのに理由が「イベントがありません」だと辻褄が合わないため）。
        reason =
          if too_early.empty?
            "対象となる業務イベントがありません"
          else
            "当日の業務イベントが全て下限時刻（#{earliest_at.strftime('%H:%M')}）より前に始まります"
          end
        return fallback(default_deadline, considered, [], too_early, reason)
      end

      excluded = []
      adopted = nil
      considered.each do |ev|
        if excluded_by_keyword?(ev)
          excluded << ev
          next
        end
        adopted = ev
        break
      end

      if adopted.nil?
        return fallback(default_deadline, considered, excluded, too_early,
                        "先頭の業務イベントが全て除外キーワードに一致しました")
      end

      deadline = [default_deadline, adopted.starts_at].min
      Plan.new(
        deadline_at: deadline,
        source: :calendar,
        adopted_event: adopted,
        excluded_events: excluded,
        too_early_events: too_early,
        considered_events: considered,
        fallback_reason: (deadline == default_deadline ? "採用イベントが所定の出勤締切より遅いため所定時刻を採用" : nil),
      )
    end

    private

    def fallback(default_deadline, considered, excluded, too_early, reason)
      Plan.new(
        deadline_at: default_deadline,
        source: :default,
        adopted_event: nil,
        excluded_events: excluded,
        too_early_events: too_early,
        considered_events: considered,
        fallback_reason: reason,
      )
    end

    # 対象: all_day:false かつ starts_at 非null かつ starts_at の日付が当日。
    def target_events(events, date)
      Array(events).select do |ev|
        !ev.all_day && !ev.starts_at.nil? && ev.starts_at.to_date == date
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
