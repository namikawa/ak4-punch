# frozen_string_literal: true

source "https://rubygems.org"

# 下限は Gemfile.lock が要求する Ruby に合わせる（bundler 4.0.14 と public_suffix 7.0.5 が
# いずれも required_ruby_version >= 3.2）。開発・CI は .ruby-version（3.4.10）で確認。
ruby ">= 3.2"

gem "holiday_jp", "~> 0.8" # 日本の祝日判定
gem "logger", "~> 1.6"     # Ruby 4.0 で標準gemから外れるため明示
gem "thor", "~> 1.3"       # CLI サブコマンド

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "webmock", "~> 3.20"
end
