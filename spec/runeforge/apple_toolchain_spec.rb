# frozen_string_literal: true

# What Runeforge tells agents about this Mac's Apple toolchain, how it checks an Apple app really
# launches before merging, and how it surfaces compiler warnings and test targets that don't build.
RSpec.describe "Apple toolchain support" do
  let(:toolchain) do
    Runeforge::Platform::AppleToolchain.new(
      xcode_version: "Xcode 27.0", developer_dir: "/Applications/Xcode.app/Contents/Developer",
      simulator_app: "/Applications/Xcode.app/Contents/Applications/DeviceHub.app",
      runtimes: { "27.0" => ["iPhone 17 Pro", "iPhone Air"], "26.2" => ["iPhone 16e"] }, tools: ["xcodegen"]
    )
  end

  describe "Platform.simulator_app" do
    let(:developer_dir) { File.join(tmpdir, "Xcode.app", "Contents", "Developer") }

    before { allow(Runeforge::Platform).to receive(:capture).with("mdfind", anything).and_return(["", false]) }

    it "finds Simulator.app up to Xcode 26" do
      FileUtils.mkdir_p(File.join(developer_dir, "Applications", "Simulator.app"))
      expect(Runeforge::Platform.simulator_app(developer_dir)).to eq(File.join(developer_dir, "Applications", "Simulator.app"))
    end

    it "finds DeviceHub.app on Xcode 27, which has no Simulator.app" do
      FileUtils.mkdir_p(File.join(tmpdir, "Xcode.app", "Contents", "Applications", "DeviceHub.app"))
      expect(Runeforge::Platform.simulator_app(developer_dir)).to eq(File.join(tmpdir, "Xcode.app", "Contents", "Applications", "DeviceHub.app"))
    end

    it "is nil when neither exists" do
      expect(Runeforge::Platform.simulator_app(developer_dir)).to be_nil
    end
  end

  describe "the agents' prompts" do
    let(:task) { { id: "T-1", title: "Add a screen", spec: "Add it.", max_attempts: 5 } }

    it "tell the planner and the coder where simulators are shown and what's installed" do
      plan = Runeforge::Prompts.plan(task:, input: { "title" => "x" }, test_globs: ["Tests/**/*"], test_command: "swift test",
                                     environment: "this machine", apple: toolchain)
      code = Runeforge::Prompts.code(task:, attempt: 1, locked_paths: [], test_command: "swift test", apple: toolchain)
      [plan, code].each do |prompt|
        expect(prompt).to include("## Apple toolchain on this machine", "DeviceHub.app`", "never hard-code `open -a Simulator`",
                                  "iOS 27.0: iPhone 17 Pro, iPhone Air", "Command-line tools installed: xcodegen",
                                  "Fix Swift concurrency warnings", "exit non-zero")
      end
    end

    it "leave other projects' prompts alone" do
      code = Runeforge::Prompts.code(task:, attempt: 1, locked_paths: [], test_command: "npm test")
      expect(code).not_to include("Apple toolchain")
    end
  end

  describe Runeforge::LaunchCheck do
    def problems(output, exit_code: 0, timed_out: false) = described_class.problems(output, exit_code, timed_out, command: "./run.sh")

    it "accepts a run that launched the app" do
      expect(problems("/x/A.swift:1:2: warning: unused\nwarning: xcodebuild's own\napp.wordreel.WordReel: 4242\n"))
        .to eq([[], "app.wordreel.WordReel"])
    end

    it "rejects a run that printed why it couldn't show the app, even when it exited 0" do
      reasons, = problems("Unable to find application named 'Simulator'\nwarning: could not open Simulator.app\napp.x.Y: 1\n")
      expect(reasons).to eq(["`./run.sh` printed: Unable to find application named 'Simulator'",
                             "`./run.sh` printed: could not open Simulator.app"])
    end

    it "rejects a run that failed, timed out or never launched the app" do
      expect(problems("No available simulator named 'iPhone 99'\n", exit_code: 1).first)
        .to include(a_string_including("failed (exit status 1)"), "`./run.sh` printed: No available simulator named 'iPhone 99'")
      expect(problems("", exit_code: nil, timed_out: true).first).to eq(["`./run.sh` timed out"])
      expect(problems("built\n").first).to eq(["`./run.sh` didn't launch the app: no `<bundle id>: <pid>` line from `xcrun simctl launch` in its output"])
    end

    describe ".applies?" do
      let(:backend) { "sqlite" }
      let(:repo) { { name: "app", url: "/src/app", platform: "apple", run_command: "./scripts/run-simulator.sh" } }

      before { allow(Runeforge::Platform).to receive(:mac?).and_return(true) }

      it "runs for an Apple app built on this Mac" do
        expect(described_class.applies?(build_env, repo)).to be(true)
      end

      it "doesn't run when turned off, sandboxed, in a dry run, off a Mac, or without a run command" do
        expect(described_class.applies?(build_env("projects" => { "/src/app" => { "launch_check" => false } }), repo)).to be(false)
        expect(described_class.applies?(build_env("sandbox" => { "mode" => "docker" }), repo)).to be(false)
        expect(described_class.applies?(build_env("dry_run" => { "enabled" => true }), repo)).to be(false)
        expect(described_class.applies?(build_env, repo.merge(platform: nil))).to be(false)
        expect(described_class.applies?(build_env, repo.merge(run_command: ""))).to be(false)
        allow(Runeforge::Platform).to receive(:mac?).and_return(false)
        expect(described_class.applies?(build_env, repo)).to be(false)
      end
    end
  end

  describe "Tester.warnings" do
    it "keeps unique Swift warnings, with paths relative to the workspace" do
      root = File.realpath(tmpdir)
      output = "\e[1m#{root}/App/Feedback.swift:58:25: warning: call to main actor-isolated initializer [#ActorIsolatedCall]\e[0m\n" \
               "#{root}/Sources/A.swift:3:1: warning: never mutated\n#{root}/Sources/A.swift:3:1: warning: never mutated\n" \
               "warning: not from the compiler\n"
      expect(Runeforge::Roles::Tester.warnings(output, root:))
        .to eq(["App/Feedback.swift:58:25: warning: call to main actor-isolated initializer [#ActorIsolatedCall]",
                "Sources/A.swift:3:1: warning: never mutated"])
    end
  end

  describe "TestProbe.build_failed" do
    it "spots a test target that doesn't compile" do
      expect(Runeforge::TestProbe.build_failed("x.swift:1: error: cannot find 'Foo' in scope\nerror: fatalError\n", 1))
        .to eq("the Swift test target doesn't compile")
      expect(Runeforge::TestProbe.build_failed("Testing cancelled because the build failed.\n** TEST FAILED **\n", 65))
        .to eq("the Swift test target doesn't compile")
      expect(Runeforge::TestProbe.build_failed("error: could not compile `app` (lib test)\n", 101)).to eq("cargo couldn't compile the tests")
    end

    it "leaves tests that built and failed alone, xcodebuild's TEST FAILED included" do
      expect(Runeforge::TestProbe.build_failed("Test Case '-[A testB]' failed\n** TEST FAILED **\n", 65)).to be_nil
      expect(Runeforge::TestProbe.build_failed("anything", 0)).to be_nil
    end
  end
end
