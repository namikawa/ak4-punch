# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "bin/daemonctl の操作契約" do
  let(:label) { "com.ak4punch.daemon" }
  let(:domain) { "gui/#{Process.uid}" }
  let(:original_plist) { "既存のplist\n" }

  # 本番のスクリプトはコピーするだけ。HOME・PATH・状態はこのディレクトリ内に閉じる。
  around do |example|
    Dir.mktmpdir("ak4-daemonctl-") do |dir|
      @fixture_root = File.join(dir, "project with spaces")
      @fake_bin = File.join(dir, "fake commands")
      @home = File.join(dir, "user home")
      @run_dir = File.join(dir, "unrelated cwd")
      @state_path = File.join(dir, "state.json")
      @calls_path = File.join(dir, "calls.jsonl")
      @script = File.join(@fixture_root, "bin", "daemonctl")
      @plist = File.join(@home, "Library", "LaunchAgents", "#{label}.plist")
      FileUtils.mkdir_p([File.dirname(@script), @fake_bin, File.dirname(@plist), @run_dir])
      FileUtils.cp(File.expand_path("../bin/daemonctl", __dir__), @script)
      File.write(@state_path, JSON.generate(loaded: false, pid: 4242, unload_after: 0,
                                            sleeps: 0, punch_mode: "success", lint_ok: true))
      File.write(@calls_path, "")
      install_fake_commands
      example.run
    end
  end

  def install_fake_commands
    # fake は許可した引数だけ受け付ける。未知操作は記録して拒否し、実コマンドへ転送しない。
    fake = "#!#{RbConfig.ruby}\n" + <<~'RUBY'
      require "json"
      name = File.basename($0)
      state_path = ENV.fetch("AK4_FAKE_STATE")
      calls_path = ENV.fetch("AK4_FAKE_CALLS")
      state = JSON.parse(File.read(state_path))
      record = ->(args) { File.open(calls_path, "a") { |f| f.puts(JSON.generate(args)) } }
      record.call([name, *ARGV])
      at_exit { File.write(state_path, JSON.generate(state)) }
      reject = -> {
        record.call(["rejected", name, *ARGV])
        warn "fake が未知の操作を拒否しました"
        exit 64
      }
      label = "com.ak4punch.daemon"
      domain = "gui/#{Process.uid}"
      plist = File.join(ENV.fetch("HOME"), "Library", "LaunchAgents", "#{label}.plist")

      case name
      when "punch"
        reject.call unless ARGV == ["launchd", "--plist-only"]
        state["punch_root"] = File.dirname(File.dirname(File.expand_path($0)))
        case state.fetch("punch_mode")
        when "failure" then puts "途中までの出力"; exit 1
        when "empty" then exit 0
        when "success" then puts "<plist><dict><key>Label</key><string>#{label}</string></dict></plist>"
        else reject.call
        end
      when "plutil"
        reject.call unless ARGV.length == 2 && ARGV[0] == "-lint" &&
                           ARGV[1].start_with?("#{plist}.") && File.file?(ARGV[1])
        abort "invalid plist" unless state.fetch("lint_ok")
        puts "OK"
      when "sleep"
        reject.call unless ARGV == ["1"] && state["bootout_pending"]
        state["sleeps"] += 1
        if state["unload_after"] && state["sleeps"] >= state["unload_after"]
          state["loaded"] = false
          state["bootout_pending"] = false
        end
      when "pmset"
        reject.call unless ARGV == ["-g", "sched"]
        puts "Scheduled power events:"
      when "launchctl"
        case ARGV
        when ["list", label] then exit(state["loaded"] ? 0 : 1)
        when ["list"] then puts "#{state['pid']} 0 #{label}" if state["loaded"]
        when ["bootout", "#{domain}/#{label}"]
          reject.call unless state["loaded"]
          state["sleeps"] = 0
          state["bootout_pending"] = true
          if state["unload_after"] == 0
            state["loaded"] = false
            state["bootout_pending"] = false
          end
        when ["bootstrap", domain, plist]
          reject.call if state["loaded"] || !File.file?(plist) || File.zero?(plist)
          state["loaded"] = true
        when ["kickstart", "-k", "#{domain}/#{label}"]
          reject.call unless state["loaded"]
        else reject.call
        end
      else reject.call
      end
    RUBY
    paths = %w[launchctl plutil sleep pmset].map { |name| File.join(@fake_bin, name) }
    paths << File.join(@fixture_root, "bin", "punch")
    paths.each do |path|
      File.write(path, fake)
      File.chmod(0o755, path)
    end
    @fake_paths = paths
  end

  def state = JSON.parse(File.read(@state_path))
  def calls = File.readlines(@calls_path).map { |line| JSON.parse(line) }
  def registration_calls = calls.select { |cmd| cmd[0] == "launchctl" && %w[bootout bootstrap kickstart].include?(cmd[1]) }
  def set_state(**values) = File.write(@state_path, JSON.generate(state.merge(values.transform_keys(&:to_s))))
  def place_plist = File.write(@plist, original_plist)
  def expect_no_temporary_plist = expect(Dir.children(File.dirname(@plist))).to eq ["#{label}.plist"]

  def run_daemonctl(command)
    # fake の欠落・権限不備でシステムのコマンドへ落ちないことを起動前に確認する。
    @fake_paths.each { |path| raise "fake が実行できません: #{path}" unless File.executable?(path) }
    env = {
      "HOME" => @home, "PATH" => "#{@fake_bin}:/usr/bin:/bin", "LC_ALL" => "C",
      "AK4_FAKE_STATE" => @state_path, "AK4_FAKE_CALLS" => @calls_path,
    }
    output, status = Open3.capture2e(env, "/bin/bash", @script, command,
                                   unsetenv_others: true, chdir: @run_dir)
    expect(calls.select { |cmd| cmd[0] == "rejected" }).to be_empty
    [output, status.exitstatus]
  end

  describe "install のplist保護" do
    [
      ["生成の異常終了", { punch_mode: "failure" }, "plist の生成に失敗"],
      ["生成の空出力", { punch_mode: "empty" }, "plist の生成結果が空"],
      ["plutil の失敗", { lint_ok: false }, "plist として不正"],
    ].each do |scenario, settings, message|
      it "#{scenario}では既存plistを保持し、登録を変更せず一時ファイルを片付ける" do
        place_plist
        set_state(loaded: true, **settings)

        output, code = run_daemonctl("install")

        expect(code).to eq 1
        expect(output).to include(message)
        expect(File.read(@plist)).to eq original_plist
        expect_no_temporary_plist
        expect(registration_calls).to be_empty
        expect(state["loaded"]).to be true
      end
    end

    it "正常生成を0644で設置し、コピー元と離れた空白入りROOTから登録する" do
      output, code = run_daemonctl("install")

      expect(code).to eq 0
      expect(output).to include("launchd に登録して起動しました")
      expect(File.read(@plist)).to include("<plist>", label)
      expect(File.stat(@plist).mode & 0o777).to eq 0o644
      expect_no_temporary_plist
      expect(state["punch_root"]).to eq @fixture_root
      expect(registration_calls).to eq [["launchctl", "bootstrap", domain, @plist]]
      expect(state["loaded"]).to be true
    end

    it "登録済みinstallはbootoutし、40回目のsleep後に解除を確認してからbootstrapする" do
      place_plist
      set_state(loaded: true, unload_after: 40)

      output, code = run_daemonctl("install")

      expect(code).to eq 0
      expect(output).to include("ロード済みのため登録し直します", "launchd に登録して起動しました")
      expect(output).not_to include("タイムアウト")
      expect(state["sleeps"]).to eq 40
      expect(registration_calls).to eq [
        ["launchctl", "bootout", "#{domain}/#{label}"], ["launchctl", "bootstrap", domain, @plist],
      ]
      expect(calls.last(3)).to eq [
        ["sleep", "1"], ["launchctl", "list", label], ["launchctl", "bootstrap", domain, @plist],
      ]
      expect_no_temporary_plist
    end

    it "登録解除がタイムアウトするとexit 1で終了しbootstrapしない" do
      place_plist
      set_state(loaded: true, unload_after: nil)

      output, code = run_daemonctl("install")

      expect(code).to eq 1
      expect(output).to include("登録解除の完了確認がタイムアウト")
      expect(state["sleeps"]).to eq 40
      expect(registration_calls).to eq [["launchctl", "bootout", "#{domain}/#{label}"]]
      expect_no_temporary_plist
    end
  end

  describe "start / restart" do
    it "plist未設置のstartはinstallして登録する" do
      output, code = run_daemonctl("start")

      expect(code).to eq 0
      expect(output).to include("plist が未設置のため install", "launchd に登録して起動しました")
      expect(calls).to include(["punch", "launchd", "--plist-only"])
      expect(registration_calls).to eq [["launchctl", "bootstrap", domain, @plist]]
      expect_no_temporary_plist
    end

    it "登録済みstartはPIDを表示し登録やプロセスを変更しない" do
      place_plist
      set_state(loaded: true)

      output, code = run_daemonctl("start")

      expect(code).to eq 0
      expect(output).to include("起動済みです（PID 4242）")
      expect(registration_calls).to be_empty
      expect(File.read(@plist)).to eq original_plist
    end

    it "登録済みrestartはkickstart -kし、plistを作り直さない" do
      place_plist
      set_state(loaded: true)

      output, code = run_daemonctl("restart")

      expect(code).to eq 0
      expect(output).to include("再起動しました")
      expect(registration_calls).to eq [["launchctl", "kickstart", "-k", "#{domain}/#{label}"]]
      expect(File.read(@plist)).to eq original_plist
    end

    it "未登録restartは設置済みplistでstartし、kickstartを使わない" do
      place_plist

      output, code = run_daemonctl("restart")

      expect(code).to eq 0
      expect(output).to include("起動していないため start", "起動しました")
      expect(registration_calls).to eq [["launchctl", "bootstrap", domain, @plist]]
      expect(File.read(@plist)).to eq original_plist
    end
  end

  describe "stop" do
    it "登録解除の完了を待って停止し、plistを残す" do
      place_plist
      set_state(loaded: true, unload_after: 2)

      output, code = run_daemonctl("stop")

      expect(code).to eq 0
      expect(output).to include("停止しました（plist は残っています")
      expect(state["loaded"]).to be false
      expect(state["sleeps"]).to eq 2
      expect(registration_calls).to eq [["launchctl", "bootout", "#{domain}/#{label}"]]
      expect(File.read(@plist)).to eq original_plist
    end

    it "未登録なら何も変更せず起動していないと表示する" do
      place_plist

      output, code = run_daemonctl("stop")

      expect(code).to eq 0
      expect(output).to include("起動していません")
      expect(registration_calls).to be_empty
      expect(state["sleeps"]).to eq 0
      expect(File.read(@plist)).to eq original_plist
    end

    it "停止確認がタイムアウトしたら通知し、既存仕様どおりexit 0で終わる" do
      place_plist
      set_state(loaded: true, unload_after: nil)

      output, code = run_daemonctl("stop")

      expect(code).to eq 0
      expect(output).to include("停止要求を送りましたが完了確認がタイムアウト")
      expect(state["loaded"]).to be true
      expect(state["sleeps"]).to eq 40
      expect(registration_calls).to eq [["launchctl", "bootout", "#{domain}/#{label}"]]
      expect(File.read(@plist)).to eq original_plist
    end
  end
end
