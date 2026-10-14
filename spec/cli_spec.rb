# frozen_string_literal: true

require "spec_helper"
# plist が XML として妥当かを確かめるためだけに使う（テスト専用。Ruby 3.4 では bundled gem
# なので Gemfile の development/test グループで明示している）。
require "rexml/document"
require "shellwords"
require "stringio"

RSpec.describe Ak4Punch::CLI do
  def launchd_output(root, plist_only: false)
    previous_stdout = $stdout
    expect(Ak4Punch::Config).not_to receive(:load)
    expect(Ak4Punch::EnvFile).not_to receive(:load)
    cli = described_class.new([], { plist_only: plist_only })
    allow(cli).to receive(:project_root).and_return(root)
    captured = StringIO.new
    $stdout = captured
    cli.launchd
    captured.string
  ensure
    $stdout = previous_stdout
  end

  def guide_commands(output)
    output.lines.select { |line| line.include?("/bin/daemonctl") || line.include?(" --plist-only") }
          .map { |line| Shellwords.split(line) }
  end

  describe "launchd の通常ガイド" do
    let(:root) { "/Users/tester/src/ak4-punch" }

    it "daemonctlの標準操作とplist-onlyの取得を設定なしで案内する" do
      commands = guide_commands(launchd_output(root))

      %w[install status restart stop start log].each do |operation|
        expect(commands).to include(["#{root}/bin/daemonctl", operation])
      end
      expect(commands).to include(["#{root}/bin/punch", "launchd", "--plist-only"])
    end

    it "旧launchctl load/unloadやXMLの直接上書き手順を含めない" do
      output = launchd_output(root)

      expect(output).not_to match(/launchctl (?:load|unload)/)
      expect(output).not_to include("cat >", "<<'PLIST'", "<plist")
    end

    it "空白・引用符・&・コマンド置換風のパスをshell引数としてそのまま復元できる" do
      ["/Users/tester/project with spaces", %q(/Users/tester/quo'te" & $(not-executed))].each do |path|
        commands = guide_commands(launchd_output(path))

        expect(commands).to contain_exactly(
          *%w[install status restart stop start log].map { |operation| ["#{path}/bin/daemonctl", operation] },
          ["#{path}/bin/punch", "launchd", "--plist-only"],
        )
      end
    end
  end

  describe "LaunchAgent plist の生成" do
    def plist_for(root) = launchd_output(root, plist_only: true)

    it "plist-onlyはガイドを含まずXMLだけを設定なしで出力する" do
      output = plist_for("/Users/tester/src/ak4-punch")

      expect(output).to start_with('<?xml version="1.0" encoding="UTF-8"?>')
      expect(output).not_to include("/bin/daemonctl", "--plist-only", "launchctl")
      expect(REXML::Document.new(output).root.name).to eq "plist"
    end

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
