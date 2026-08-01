# frozen_string_literal: true

require "json"
require "fileutils"

module Ak4Punch
  # アクセストークンの永続化と自動再発行。
  # AKASHI のトークン有効期限は「1ヶ月と1日」。期限が閾値以内になったら
  # 再発行APIで更新し token.json に書き戻す（初回は seed から生成し、
  # 有効期限が不明なため一度再発行して期限を確定させる）。
  class TokenStore
    def self.load(path:, seed_token:, threshold_days: 7)
      data = {}
      if File.exist?(path)
        data = (JSON.parse(File.read(path)) rescue {})
      end
      new(
        path: path,
        token: (data["token"] && !data["token"].empty? ? data["token"] : seed_token),
        expired_at: Ak4Punch.parse_akashi_time(data["expired_at"]),
        threshold_days: threshold_days,
      )
    end

    attr_reader :token, :expired_at, :path

    def initialize(path:, token:, expired_at:, threshold_days: 7)
      @path = path
      @token = token
      @expired_at = expired_at
      @threshold_days = threshold_days
    end

    # 有効期限が不明、または閾値以内なら再発行が必要。
    def needs_refresh?(now: Ak4Punch.now)
      return true if @expired_at.nil?

      @expired_at - now <= @threshold_days * 86_400
    end

    # client を使ってトークンを再発行し、保存する。
    def refresh!(client)
      client.token = @token
      result = client.reissue_token
      new_token = result[:token]
      raise "トークン再発行に失敗しました（新トークンが空。トークン失効の可能性。マイページで再発行し .env を更新してください）" if new_token.nil? || new_token.empty?

      @token = new_token
      @expired_at = result[:expired_at]
      client.token = @token
      persist!
      self
    end

    # 一時ファイルへ書いてから rename で置き換える（atomic write）。
    # 直接上書きすると書き込み途中の異常終了（電源断・強制終了）で JSON が壊れ、
    # load が .env のシードトークンへ落ちてしまう。再発行済みならシードは失効している
    # 可能性が高く、手動での再発行が必要になるため確実に「壊れた中身」を作らない。
    # 一時ファイルは最初から 0600 で作る（後追いの chmod と違い一瞬も緩まず、umask にも左右されない）。
    def persist!
      FileUtils.mkdir_p(File.dirname(@path))
      json = JSON.pretty_generate(
        "token" => @token,
        "expired_at" => Ak4Punch.format_akashi_time(@expired_at),
      )
      # 一時ファイル名は PID で一意にする。デーモンと手動コマンド（refresh_token 等）が
      # 同時に保存しても互いの一時ファイルを掴まず、置き換えが常に rename 単位で完結する
      # （1プロセス内はシングルスレッドなので PID だけで十分）。
      tmp = "#{@path}.tmp.#{Process.pid}"
      begin
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
          f.write(json)
          f.flush
          f.fsync # rename 前にディスクへ確実に書き出す
        end
        File.rename(tmp, @path) # 同一ディレクトリ内の rename は原子的（権限 0600 も引き継がれる）
      ensure
        # 失敗時に書きかけの一時ファイルを残さない（成功時は rename 済みで存在しない）。
        File.unlink(tmp) if File.exist?(tmp)
      end
    end
  end
end
