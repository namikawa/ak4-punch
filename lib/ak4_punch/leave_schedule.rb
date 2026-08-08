# frozen_string_literal: true

require "date"

module Ak4Punch
  # その日の「休暇」イベント（タイトルが leave_keywords に部分一致するイベント）の集合。
  #
  # 休暇イベントは「その時間帯は勤務しない」という意味であって、当日を丸ごと休みにする
  # 二値のフラグではない（午前休・午後休をそのまま打刻に反映するため）。扱いは3つ:
  #   1. 業務イベントの判定（ClockInPlanner / ClockOutPlanner）からは常に除外する
  #   2. 出勤の打刻締切が休暇の時間帯に入っていたら、その終了時刻へ後ろ倒しする（push_after）
  #   3. 退勤の基準時刻が休暇の時間帯に入っていたら、その開始時刻へ前倒しする（push_before）
  # 押し出しの結果「出勤締切 >= 退勤基準」になった日が全休（判定は Daemon#full_leave?）。
  # 終日イベントも 00:00〜翌00:00 の休暇として同じ経路で全休になるため、全休は特別ルール
  # ではなく押し出しの帰結になる。
  #
  # 押し出しは必ず「所定・カレンダーから基準を決めた後」に適用する（順序が本質）。
  # 「休暇が退勤時刻を覆っていたら休暇の開始で退勤」という単純な規則にすると、
  # 休暇 15:00-19:00 の後に会議 19:00-20:00 がある日（＝中抜け）の退勤が 15:00 になってしまう。
  # 基準を先に求めれば max(所定, 最終業務イベント終了)=20:00 が休暇の外なので押し出しは起きない。
  #
  # AKASHI は休暇申請日でも打刻を受理し（実機確認済み）、公開APIから休暇申請を読む手段も
  # ないため、この判定が休暇日の誤打刻を防ぐ主手段になる。
  class LeaveSchedule
    # 休暇1件の時間帯。閉区間 [starts_at, ends_at] として扱う。
    Period = Struct.new(:starts_at, :ends_at, :event, keyword_init: true) do
      # 端点一致も「時間帯の中」とみなす（閉区間）。休暇 15:00-18:00 の日の退勤基準 18:00 は
      # 「休暇の終わりに退勤」ではなく「15:00 に退勤済み」が正しいため。
      # 逆向きの端点（休暇 18:00-19:00 と退勤基準 18:00 など）は押し出しても値が動かないので、
      # push 側の「値が動く休暇だけを採用する」条件で自然に止まる。
      def cover?(time) = time >= starts_at && time <= ends_at

      # ログ・`punch plan` 用の表示。例: 『午前休』(09:00-12:00) / 『夏季休暇』(終日)
      def label = "『#{event.display_title}』(#{range_label})"

      def range_label
        return "終日" if event.all_day

        "#{starts_at.strftime('%H:%M')}-#{LeaveSchedule.hhmm(ends_at, base: starts_at)}"
      end
    end

    # 押し出しの記録（発生した根拠をログ・`punch plan` に出すため）。
    Shift = Struct.new(:from, :to, :period, keyword_init: true) do
      # 例: 休暇『午前休』(09:00-12:00) により 09:30 → 12:00
      def label
        "休暇#{period.label} により #{LeaveSchedule.hhmm(from)} → #{LeaveSchedule.hhmm(to, base: from)}"
      end
    end

    # 日を跨いだ時刻は日付も添えて表示する（終日休暇の押し出し先は翌日 00:00 になるため）。
    def self.hhmm(time, base: nil)
      return time.strftime("%H:%M") if base.nil? || time.to_date == base.to_date

      time.strftime("%m/%d %H:%M")
    end

    # events: CalendarClient::Event 配列（nil 可＝連動OFF・取得失敗。休暇なしとして扱う）
    # keywords: 休暇と見なすタイトルのキーワード（部分一致・時間の閾値はなし）
    # date: 対象日(Date)。終日・時刻欠落イベントの時間帯をこの日を基準に正規化する。
    def self.build(events:, keywords:, date:)
      kws = Array(keywords).map(&:to_s).reject(&:empty?)
      leaves, works = Array(events).partition { |ev| leave_title?(ev, kws) }
      new(leave_events: leaves, work_events: works, date: date)
    end

    # title が nil・空のイベントは休暇にしない（業務イベント扱い）。
    def self.leave_title?(event, keywords)
      title = event.title
      return false if title.nil? || title.to_s.empty?

      keywords.any? { |kw| title.include?(kw) }
    end
    private_class_method :leave_title?

    # events: 休暇イベント配列 / work_events: 休暇以外のイベント配列 / periods: 正規化した時間帯
    attr_reader :events, :work_events, :periods

    def initialize(leave_events:, work_events:, date:)
      @events = leave_events
      @work_events = work_events
      @periods = leave_events.map { |ev| build_period(ev, date) }
    end

    def any? = !@events.empty?

    # 指定時刻がいずれかの休暇の時間帯に入っているか。
    def covers?(time) = @periods.any? { |p| p.cover?(time) }

    # ログ表示用。例: 『午前休』(09:00-12:00)、『午後休』(13:00-19:00)
    def labels = @periods.map(&:label).join("、")

    # 時刻を休暇の外へ後ろ倒しする（出勤の打刻締切用）。
    # 戻り値: [押し出し後の時刻, Shift 配列（空なら押し出しなし）]
    def push_after(time) = push(time, :ends_at)

    # 時刻を休暇の外へ前倒しする（退勤の基準時刻用）。
    def push_before(time) = push(time, :starts_at)

    private

    # 時刻が休暇の時間帯に入っている間、edge（:ends_at=後ろへ / :starts_at=前へ）に押し出す。
    # 押し出し先が別の休暇に入ることがある（午前休→午後休が連続する日など）ので、
    # 動かなくなるまで繰り返す。
    #
    # 「edge != time」が空回り防止の要。cover? が成り立つとき ends_at >= time / starts_at <= time
    # なので、この条件は「押し出しても値が実際に動く」ことと同値になる。時刻は毎回、有限個の
    # 端点のどれかへ厳密に単調移動するため、必ず有限回で止まる（無限ループしない）。
    def push(time, edge)
      shifts = []
      loop do
        hit = @periods.find { |p| p.cover?(time) && p.public_send(edge) != time }
        break if hit.nil?

        moved = hit.public_send(edge)
        shifts << Shift.new(from: time, to: moved, period: hit)
        time = moved
      end
      [time, shifts]
    end

    # 休暇1件を時間帯に正規化する。
    #   終日イベント     → 当日 00:00 〜 翌日 00:00（時刻を持たない・持っていても当てにしない）
    #   時刻が欠けた場合 → 欠けた側を当日 00:00 / 翌日 00:00 で補う（判定不能な側は広く取る）
    # 終日をこの区間にするのは、出勤締切が翌日 00:00・退勤基準が当日 00:00 へ押し出され、
    # 「出勤締切 >= 退勤基準」＝全休に自然に落ちるため（全休を特別扱いしないための正規化）。
    def build_period(event, date)
      day_start = Time.new(date.year, date.month, date.day, 0, 0, 0, Ak4Punch::JST)
      day_end = day_start + (24 * 60 * 60)
      return Period.new(starts_at: day_start, ends_at: day_end, event: event) if event.all_day

      Period.new(starts_at: event.starts_at || day_start,
                 ends_at: event.ends_at || day_end,
                 event: event)
    end
  end
end
