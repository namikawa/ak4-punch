# frozen_string_literal: true

module Ak4Punch
  # 1回分の打刻ユースケース（出勤 or 退勤）。
  # 対象日判定 → 冪等チェック → 打刻 の順で、実行時刻に記録する。
  class Stamper
    TYPE  = { in: 11, out: 12 }.freeze
    LABEL = { in: "出勤", out: "退勤" }.freeze

    Result = Struct.new(:status, :kind, :type, :message, :recorded_at, keyword_init: true)

    # sleeper/rng は待機の副作用を差し替え可能にするため注入（テスト用）。
    def initialize(config:, client:, calendar:, logger: nil, sleeper: Kernel.method(:sleep), rng: Random)
      @config = config
      @client = client
      @calendar = calendar
      @logger = logger
      @sleeper = sleeper
      @rng = rng
    end

    # kind: :in / :out
    # window_minutes: 0 なら指定時刻ちょうど。>0 なら 0〜N分のランダムな時刻まで待ってから打刻する
    # （AKASHI は記録時刻＝リクエスト到着時刻のため、待機＝記録時刻の後ろ倒し）。
    def punch(kind:, date: Ak4Punch.today, force: false, dry_run: false, window_minutes: 0)
      type   = TYPE.fetch(kind)
      label  = LABEL.fetch(kind)
      window = window_minutes.to_i

      unless force
        skip = @calendar.reason(date)
        return result(:skipped, kind, type, "#{date} は対象日ではないためスキップ（#{skip}）") if skip
      end

      if dry_run
        detail = window.positive? ? "（指定時刻から0〜#{window}分後のランダムな時刻に記録されます）" : "（実行時刻で記録されます）"
        return result(:dry_run, kind, type, "[dry-run] #{label}(type=#{type})を打刻します#{detail}")
      end

      # ランダムウィンドウ分だけ待機してから、当日の重複を確認して打刻する。
      # 冪等チェックを待機後に行うことで、待機中の手動打刻も検出できる。
      wait_for_jitter(window, label) if window.positive?

      if @config.check_existing && !force
        if @client.stamped_types(date: date).include?(type)
          return result(:skipped, kind, type, "#{date} は既に#{label}打刻済みのためスキップ")
        end
      end

      res = @client.post_stamp(type: type)
      result(:punched, kind, type, "#{label}を打刻しました", recorded_at: res[:stamped_at])
    end

    private

    # 0〜window_minutes分のランダムな秒数だけ待機する（人間らしさのため）。
    def wait_for_jitter(window_minutes, label)
      delay = @rng.rand(0..(window_minutes * 60))
      @logger&.info("人間らしさのため #{delay}秒（約#{(delay / 60.0).round(1)}分）待機してから#{label}を打刻します")
      @sleeper.call(delay)
    end

    def result(status, kind, type, message, recorded_at: nil)
      full = recorded_at ? "#{message}（記録時刻=#{recorded_at}）" : message
      @logger&.info(full)
      Result.new(status: status, kind: kind, type: type, message: full, recorded_at: recorded_at)
    end
  end
end
