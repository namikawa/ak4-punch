# frozen_string_literal: true

module Ak4Punch
  # pmset の「一回限り起床予約」を add-only 方式で管理する小さなクラス。
  # Daemon の tick 毎に、当日の残り打刻目標（と翌営業日朝のブートストラップ）の
  # 「目標時刻 - wake_lead_minutes」に起床予約が入っている状態へ突き合わせる。
  #
  # なぜ cancelall / cancel を使わないか（重要）:
  #   pmset schedule cancelall（および cancel）は、このプロセスの予約だけでなく
  #   マシン全体の一回限り起床予約を消してしまう。しかも pmset -g sched の表示では
  #   予約の所有者を区別できないため、他プロセスの予約だけ残すことができない。
  #   同じ Mac に同居する capital-arena（仮想取引デーモン）も pmset 起床を使うため、
  #   cancelall 方式だと互いの起床予約を消し合ってしまう。そこで本クラスは
  #   「何も消さず、足りない予約だけ追加する（add-only）」方式にする。
  #     - 毎回 pmset -g sched を読み（sudo 不要）、必要な起床のうち未登録のものだけ
  #       sudo -n pmset schedule wake で追加する。
  #     - 不要になった自分の過去予約は放置してよい（一回限り予約は時刻経過で自然消滅し、
  #       万一発火しても Mac が一瞬起きるだけで無害）。
  #     - 副作用として、他デーモンが cancelall で自分の予約を消しても、次のポーリング
  #       （tick_seconds 以内）で再追加され自己回復する。
  #
  #   pmset -g sched の該当行:
  #     [0]  wake at 07/10/2026 09:29:00 by 'pmset'
  #   sudoers 未設定（パスワードが要る）環境では書き込み（schedule wake）の sudo -n が
  #   即失敗するため、警告ログを出して当日中は wake 管理を無効化する（クラッシュさせない）。
  #   読み取り（-g sched）は sudo 不要なので、読み取り失敗は無効化せず次回に再試行する。
  class WakeScheduler
    PMSET = "/usr/bin/pmset"
    PMSET_TIME_FORMAT = "%m/%d/%Y %H:%M:%S"
    # 「... wake at <MM/DD/YYYY HH:MM:SS> by 'pmset'」の行だけを対象にする。
    # 繰返しイベント（wakepoweron ...）や他所有者（by 'powerd' 等）は一致しない。
    WAKE_LINE = %r{wake at (\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}) by 'pmset'}

    # runner: [String...] を受け取り [stdout+stderr(String), success(Boolean)] を返す書き込み実行器
    #         （sudo -n pmset schedule wake 用）。既定は Open3。
    # reader: 引数なしで [pmset -g sched の出力(String), success(Boolean)] を返す読み取り器
    #         （sudo 不要）。既定は Open3。
    # clock:  現在時刻(Time)を返す。既定は Ak4Punch.now（JST）。
    def initialize(lead_minutes:, logger: nil, runner: nil, reader: nil, clock: nil)
      @lead_minutes = lead_minutes.to_i
      @logger = logger
      @runner = runner || method(:default_runner)
      @reader = reader || method(:default_reader)
      @clock = clock || -> { Ak4Punch.now }
      @disabled = false
    end

    # sudoers 未設定などで当日無効化されているか。
    def disabled? = @disabled

    # 当日無効化を解除する（日付が変わったら呼ぶ）。
    def reset! = (@disabled = false)

    # pmset -g sched の出力から自分（by 'pmset'）の一回限り起床予約時刻を Set<Time> で返す。
    # 形式に合わない行・他所有者・パース不能な時刻はスキップする。時刻は JST として解釈する。
    def self.parse_pmset_wakes(output)
      output.to_s.each_line.each_with_object(Set.new) do |line, set|
        stamp = WAKE_LINE.match(line)&.captures&.first
        next unless stamp

        begin
          set << Time.strptime("#{stamp} +0900", "#{PMSET_TIME_FORMAT} %z")
        rescue ArgumentError
          next # 正規表現は通ったが実在しない日時（例 13/40/...）はスキップ
        end
      end
    end

    # targets: 起床させたい打刻目標時刻(Time)の配列。
    # 既存の予約は一切消さず、各目標の lead 分前（未来のもの）のうち未登録のものだけ追加する。
    def reschedule(targets)
      return if @disabled

      out, ok = @reader.call
      unless ok
        # 読み取りは sudo 不要なので sudoers とは無関係。無効化せず次回ポーリングで再試行する。
        @logger&.warn("pmset -g sched の読み取りに失敗しました（次回のポーリングで再試行します）: #{out.to_s.strip}")
        return
      end

      scheduled = self.class.parse_pmset_wakes(out).map { |t| fmt(t) }
      now = @clock.call
      missing =
        Array(targets)
        .map { |t| t - (@lead_minutes * 60) }
        .select { |wake_at| wake_at > now }
        .reject { |wake_at| scheduled.include?(fmt(wake_at)) }
        .uniq { |wake_at| fmt(wake_at) }
        .sort
      return if missing.empty? # 全て揃っている → 何もしない（ログも出さない）

      missing.each do |wake_at|
        arg = fmt(wake_at)
        if run(["schedule", "wake", arg])
          @logger&.info("起床予約を追加: #{arg}（打刻#{@lead_minutes}分前）")
        else
          disable!("pmset schedule wake の予約に失敗しました（sudoers 未設定の可能性）。当日は自動起床予約を無効化します。`punch sudoers` を参照。")
          return
        end
      end
    end

    private

    def fmt(time) = time.strftime(PMSET_TIME_FORMAT)

    def disable!(message)
      @disabled = true
      @logger&.warn(message)
    end

    def run(pmset_args)
      _out, ok = @runner.call(["sudo", "-n", PMSET, *pmset_args])
      ok
    end

    def default_runner(cmd)
      require "open3"
      out, status = Open3.capture2e(*cmd)
      [out, status.success?]
    rescue StandardError => e
      ["#{e.class}: #{e.message}", false]
    end

    # 予約状態の読み取りは特権不要（sudo を付けない）。
    def default_reader
      require "open3"
      out, status = Open3.capture2e(PMSET, "-g", "sched")
      [out, status.success?]
    rescue StandardError => e
      ["#{e.class}: #{e.message}", false]
    end
  end
end
