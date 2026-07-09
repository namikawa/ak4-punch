# frozen_string_literal: true

module Ak4Punch
  # 依存 gem なしの簡易 .env ローダ。KEY=VALUE 形式のみ対応。
  # 既に環境変数がある場合は上書きしない（実環境の値を優先）。
  module EnvFile
    module_function

    def load(path)
      return unless File.exist?(path)

      # cron 等の US-ASCII ロケールでも日本語コメントで壊れないよう UTF-8 で読む。
      File.readlines(path, encoding: "UTF-8").each do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        key, sep, value = line.partition("=")
        next if sep.empty?

        ENV[key.strip] ||= value.strip.gsub(/\A["']|["']\z/, "")
      end
    end
  end
end
