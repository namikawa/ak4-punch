# frozen_string_literal: true

require "spec_helper"
# plist が XML として妥当かを確かめるためだけに使う（テスト専用。Ruby 3.4 では bundled gem
# なので Gemfile の development/test グループで明示している）。
require "rexml/document"

RSpec.describe Ak4Punch::CLI do
  describe "LaunchAgent plist の生成" do
    subject(:cli) { described_class.new }

    def plist_for(root) = cli.send(:build_launchd_plist, root)

    # plist の dict は <key> の直後の要素が値になる。key 名で値の要素を引く。
    def value_element(xml, key)
      dict = REXML::XPath.first(REXML::Document.new(xml), "/plist/dict")
      children = dict.elements.to_a
      index = children.index { |e| e.name == "key" && e.text == key }
      raise "key が見つかりません: #{key}" if index.nil?

      children[index + 1]
    end

    it "XML として解析でき、必要なキーを持つ" do
      xml = plist_for("/Users/tester/src/ak4-punch")

      expect(value_element(xml, "Label").text).to eq "com.ak4punch.daemon"
      expect(value_element(xml, "WorkingDirectory").text).to eq "/Users/tester/src/ak4-punch"
      expect(value_element(xml, "StandardOutPath").text).to eq "/Users/tester/src/ak4-punch/punch.log"
      expect(value_element(xml, "StandardErrorPath").text).to eq "/Users/tester/src/ak4-punch/punch.log"
      expect(value_element(xml, "ProgramArguments").elements.to_a.map(&:text))
        .to eq ["/Users/tester/src/ak4-punch/bin/punch", "daemon"]
    end

    it "Umask を10進の 63（=8進 077）で出力する" do
      # plist の <integer> は10進。077 と書くと 8進 077 にならず group/other に読み取りが残る。
      # punch.log にはカレンダーの予定タイトルが載るため、本人だけが読める権限で作らせる。
      xml = plist_for("/Users/tester/src/ak4-punch")
      element = value_element(xml, "Umask")

      expect(element.name).to eq "integer"
      expect(element.text).to eq "63"
      expect(xml).to include("<integer>63</integer>")
    end

    it "パスに含まれる & や < を XML エスケープする（壊れた plist を設置しない）" do
      root = %(/Users/tester/R&D/a<b>c"d)
      xml = plist_for(root)

      expect(xml).to include("/Users/tester/R&amp;D/a&lt;b&gt;c&quot;d")
      expect(xml).not_to include("R&D")
      # 実体参照以外の生の & が残っていないこと（& を最後に置換すると &amp;amp; になる）
      expect(xml.scan(/&(?!amp;|lt;|gt;|quot;|apos;)/)).to be_empty
      # エスケープしても解析後は元のパスに戻る
      expect(value_element(xml, "WorkingDirectory").text).to eq root
      expect(value_element(xml, "StandardOutPath").text).to eq "#{root}/punch.log"
      expect(value_element(xml, "ProgramArguments").elements.to_a.first.text).to eq "#{root}/bin/punch"
    end

    it "ruby の bindir を含む PATH を出力する" do
      xml = plist_for("/Users/tester/src/ak4-punch")
      env = value_element(xml, "EnvironmentVariables")
      children = env.elements.to_a
      path = children[children.index { |e| e.name == "key" && e.text == "PATH" } + 1].text

      expect(path).to start_with "#{File.dirname(RbConfig.ruby)}:"
    end
  end
end
