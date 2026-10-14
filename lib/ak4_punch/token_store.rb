# frozen_string_literal: true

require "json"
require "fileutils"

module Ak4Punch
  # アクセストークンの永続化と自動再発行。
  # AKASHI のトークン有効期限は「1ヶ月と1日」。期限が閾値以内になったら
  # 再発行APIで更新し token.json に書き戻す（初回は seed から生成し、
  # 有効期限が不明なため一度再発行して期限を確定させる）。
  class TokenStore
    class Error < StandardError; end

    def self.load(path:, seed_token:, threshold_days: 7)
      begin
        data = JSON.parse(File.read(path))
      rescue Errno::ENOENT
        return new(path: path, token: seed_token, expired_at: nil, threshold_days: threshold_days)
      rescue SystemCallError, IOError => e
        raise Error, "トークン保存ファイルを読み取れません（#{e.class}）", cause: nil
      rescue JSON::ParserError => e
        raise Error, "トークン保存ファイルのJSONが不正です（#{e.class}）", cause: nil
      end

      raise Error, "トークン保存ファイルのJSONはオブジェクトである必要があります", cause: nil unless data.is_a?(Hash)
      unless data["token"].is_a?(String) && !data["token"].empty?
        raise Error, "トークン保存ファイルのtokenは空でない文字列である必要があります", cause: nil
      end
      unless data["expired_at"].nil? || data["expired_at"].is_a?(String)
        raise Error, "トークン保存ファイルのexpired_atは文字列またはnullである必要があります", cause: nil
      end

      new(
        path: path,
        token: data["token"],
        expired_at: Ak4Punch.parse_akashi_time(data["expired_at"]),
        threshold_days: threshold_days,
      )
    end

    attr_reader :token, :expired_at

    def initialize(path:, token:, expired_at:, threshold_days: 7)
      @path = path
      @token = token
      @expired_at = expired_at
      @threshold_days = threshold_days
      @persist_pending = false
    end

    # 保存待ち、または有効期限が不明・閾値以内なら更新が必要。
    def needs_refresh?(now: Ak4Punch.now)
      return true if @persist_pending || @expired_at.nil?

      @expired_at - now <= @threshold_days * 86_400
    end

    # client を使ってトークンを再発行し、保存する。保存待ちなら再発行せず保存だけ再試行する。
    def refresh!(client)
      client.token = @token
      unless @persist_pending
        result = client.reissue_token
        new_token = result[:token]
        raise "トークン再発行に失敗しました（新トークンが空。トークン失効の可能性。マイページで再発行し .env を更新してください）" if new_token.nil? || new_token.empty?

        @token = new_token
        @expired_at = result[:expired_at]
        client.token = @token
        @persist_pending = true
      end
      persist!
      self
    end

    # 一時ファイルへ書いてから rename で置き換える（atomic write）。
    # 直接上書きすると書き込み途中の異常終了（電源断・強制終了）で JSON が壊れ、
    # 次回の load で起動が止まるため、保存済みのトークンを壊さずに置き換える。
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
      @persist_pending = false
    end
  end
end
