# frozen_string_literal: true

module Ak4Punch
  # pmset の「一回限り起床予約」を管理する小さなクラス。
  # 計画確定/変更のたびに残っている当日の打刻予定について
  # 「目標時刻 - wake_lead_minutes」の起床を予約し直す。
  #
  #   sudo -n pmset schedule cancelall           … 既存の一回限り予約を消す
  #   sudo -n pmset schedule wake "MM/DD/YYYY HH:MM:SS" … 各予定分を予約
  #
  # sudoers 未設定（パスワードが要る）環境では sudo -n が即失敗するため、
  # 警告ログを出して当日中は wake 管理を無効化する（クラッシュさせない）。
  class WakeScheduler
    PMSET = "/usr/bin/pmset"

    # runner: [String...] を受け取り [stdout+stderr(String), success(Boolean)] を返す実行器。
    #   テストではモックを注入する。既定は Open3 で実行。
    def initialize(lead_minutes:, logger: nil, runner: nil)
      @lead_minutes = lead_minutes.to_i
      @logger = logger
      @runner = runner || method(:default_runner)
      @disabled = false
    end

    # sudoers 未設定などで当日無効化されているか。
    def disabled? = @disabled

    # 当日無効化を解除する（日付が変わったら呼ぶ）。
    def reset! = (@disabled = false)

    # targets: 起床させたい打刻目標時刻(Time)の配列（未来のもののみ渡す想定）。
    # 既存の一回限り予約をクリアしてから、各目標の lead 分前を予約し直す。
    def reschedule(targets)
      return if @disabled

      unless run(["schedule", "cancelall"])
        disable!("sudo -n pmset が実行できません（sudoers 未設定の可能性）。当日は自動起床予約を無効化します。`punch sudoers` を参照。")
        return
      end

      Array(targets).sort.each do |t|
        wake_at = t - (@lead_minutes * 60)
        arg = wake_at.strftime("%m/%d/%Y %H:%M:%S")
        if run(["schedule", "wake", arg])
          @logger&.info("起床予約: #{arg}（打刻#{@lead_minutes}分前）")
        else
          disable!("pmset schedule wake の予約に失敗しました。当日は自動起床予約を無効化します。")
          return
        end
      end
    end

    private

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
  end
end
