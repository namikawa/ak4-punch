# frozen_string_literal: true

require "json"
require "time"
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
        expired_at: parse_time(data["expired_at"]),
        threshold_days: threshold_days,
      )
    end

    def self.parse_time(str)
      return nil if str.nil? || str.to_s.strip.empty?

      Time.strptime("#{str} +0900", "%Y/%m/%d %H:%M:%S %z")
    rescue ArgumentError
      nil
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

    def persist!
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate(
        "token" => @token,
        "expired_at" => @expired_at&.strftime("%Y/%m/%d %H:%M:%S"),
      ))
      File.chmod(0o600, @path)
    end
  end
end
