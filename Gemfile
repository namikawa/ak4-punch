# frozen_string_literal: true

source "https://rubygems.org"

# 下限は Gemfile.lock が要求する Ruby に合わせる（bundler 4.0.20 と public_suffix 7.0.5 が
# いずれも required_ruby_version >= 3.2）。開発・CI は .ruby-version（3.4.10）で確認。
ruby ">= 3.2"

gem "holiday_jp", "~> 0.8" # 日本の祝日判定
gem "logger", "~> 1.6"     # Ruby 4.0 で標準gemから外れるため明示
gem "thor", "~> 1.3"       # CLI サブコマンド

group :development, :test do
  # plist の XML 検証に使う。Ruby 3.4 では bundled gem（＝Gemfile に無いと bundle exec 下で
  # require できない）ので、webmock → crack の推移依存に頼らず明示する。
  gem "rexml", "~> 3.4"
  gem "rspec", "~> 3.13"
  gem "webmock", "~> 3.26"
end
