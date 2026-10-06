# frozen_string_literal: true

RSpec.describe Runeforge::Build do
  describe ".parse" do
    it "treats a prompt as one step titled by its first line" do
      input = described_class.parse("Build a CLI that greets people\nwith colors")
      expect(input.title).to eq("Build a CLI that greets people")
      expect(input.steps.map(&:body)).to eq(["Build a CLI that greets people\nwith colors"])
    end

    it "splits a task list file into steps, skipping checked items and keeping indented detail" do
      file = File.join(tmpdir, "plan.md")
      File.write(file, <<~MD)
        # Greeter

        Some context about the project.

        - [x] Set up the repo
        - [ ] Add a greeting
          It should say hello.
        - [ ] Add a farewell
      MD
      input = described_class.parse(file)

      expect(input.title).to eq("Greeter")
      expect(input.steps.map(&:title)).to eq(["Add a greeting", "Add a farewell"])
      expect(input.steps.first.body).to eq("Add a greeting\n  It should say hello.")
    end

    it "builds a file without a list, or with a single item, as one step" do
      file = File.join(tmpdir, "one.md")
      File.write(file, "# Tiny\n\n- just this\n")
      expect(described_class.parse(file).steps.size).to eq(1)
    end

    it "refuses empty input and fully checked lists" do
      expect { described_class.parse("  ") }.to raise_error(Runeforge::Error, /prompt is empty/)
      file = File.join(tmpdir, "done.md")
      File.write(file, "- [x] a\n- [x] b\n")
      expect { described_class.parse(file) }.to raise_error(Runeforge::Error, /already checked off/)
    end
  end

  context "running" do
    let(:backend) { "sqlite" }
    let(:out) { StringIO.new }

    # Planner: writes a test for whichever word the step mentions, plus project.json.
    # Coder: writes lib/<word>.txt so that test passes.
    let(:plan_script) do
      <<~SH
        word=$(sed -n '/^## This step/,$p;/^## The request/,$p' .runeforge/prompt.md | grep -o -m1 -E 'greeting|farewell')
        mkdir -p test
        printf 'Say %s.\\n' "$word" > .runeforge/spec.md
        printf 'grep -q %s lib/%s.txt\\n' "$word" "$word" > "test/${word}_test.sh"
        printf '{"test_command": "for t in test/*_test.sh; do sh $t || exit 1; done", "tools": %s}' "${TOOLS:-[]}" > .runeforge/project.json
      SH
    end
    let(:code_script) do
      <<~SH
        word=$(grep -o -m1 -E 'greeting|farewell' .runeforge/prompt.md)
        mkdir -p lib
        echo "$word" > "lib/${word}.txt"
      SH
    end

    def build_env_for(tools: "[]", manual_merge: false)
      agent = fake_agent(plan: "TOOLS='#{tools}'\n#{plan_script}", code: code_script)
      build_env("agent" => { "command" => "sh #{agent}" }, "manual_merge" => manual_merge)
        .tap { |env| env.github = Helpers::FakeGitHub.new(opens_prs: false) }
    end

    def run_build(env, input, dir: nil, answers: "")
      described_class.new(env, input:, dir:, stdin: answers.is_a?(String) ? StringIO.new(answers) : answers, stdout: out).run
    end

    def git(dir, *args) = sh!("git", *args, dir:)

    def make_project(files = { "README.md" => "hi\n" })
      dir = File.join(tmpdir, "existing")
      FileUtils.mkdir_p(dir)
      files.each { |name, body| File.write(File.join(dir, name), body) }
      git(dir, "init", "-q", "-b", "main")
      git(dir, "add", "-A")
      git(dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "init")
      dir
    end

    it "asks for a directory, creates the project and merges the work into main" do
      env = build_env_for
      target = File.join(tmpdir, "greeter")
      expect(run_build(env, "Add a greeting", answers: "#{target}\n")).to be(true)

      expect(out.string).to include("✓ merged into main", "Done. The work is merged into main")
      expect(git(target, "branch", "--show-current").strip).to eq("main")
      expect(git(target, "status", "--porcelain")).to be_empty
      expect(File.read(File.join(target, "lib", "greeting.txt"))).to eq("greeting\n")
      expect(git(target, "branch", "--list", "runeforge/*")).to be_empty
      expect(env.tasks.list.first[:merged_sha]).to eq(git(target, "rev-parse", "main").strip)
      # New projects start with the plan inbox.
      expect(git(target, "show", "main~0:runeforge/README.md", "--format=")).to include("# Runeforge inbox")
      expect(git(target, "log", "--format=%s", "main").lines.map(&:strip)).not_to include("runeforge: add the inbox folder")
    end

    it "gives each step its own branch, merged before the next step starts" do
      env = build_env_for
      plan = File.join(tmpdir, "plan.md")
      File.write(plan, "# Greeter\n\n- Add a greeting\n- Add a farewell\n")
      target = File.join(tmpdir, "greeter")
      expect(run_build(env, plan, answers: "#{target}\n")).to be(true)

      tasks = env.tasks.list.sort_by { |task| task[:id] }
      expect(tasks.map { |task| task[:branch] }).to eq(%w[runeforge/greeter-s1 runeforge/greeter-s2])
      expect(tasks.last[:base_sha]).to eq(tasks.first[:merged_sha])
      expect(Dir.children(File.join(target, "lib")).sort).to eq(%w[farewell.txt greeting.txt])
      expect(git(target, "log", "--format=%s", "main").lines.map(&:strip)).to include("runeforge: plan for #{tasks.last[:id]}")
      expect(git(target, "branch", "--list", "runeforge/*")).to be_empty
    end

    it "fast-forwards main in --dir when it's checked out and clean" do
      env = build_env_for
      dir = make_project
      expect(run_build(env, "Add a greeting", dir:)).to be(true)

      expect(git(dir, "branch", "--show-current").strip).to eq("main")
      expect(git(dir, "status", "--porcelain")).to be_empty
      expect(File.read(File.join(dir, "lib", "greeting.txt"))).to eq("greeting\n")
    end

    it "merges into whichever branch was checked out when the build started" do
      env = build_env_for
      dir = make_project
      git(dir, "switch", "-q", "-c", "feature")
      expect(run_build(env, "Add a greeting", dir:)).to be(true)

      expect(out.string).to include("✓ merged into feature")
      expect(git(dir, "show", "feature:lib/greeting.txt")).to eq("greeting\n")
      expect(git(dir, "rev-parse", "main").strip).not_to eq(git(dir, "rev-parse", "feature").strip)
    end

    it "leaves the branch when the checkout has uncommitted changes by merge time" do
      env = build_env_for
      dir = make_project
      original = env.repos.method(:merge)
      allow(env.repos).to receive(:merge) do |*args, **kwargs|
        File.write(File.join(dir, "README.md"), "edited meanwhile\n")
        original.call(*args, **kwargs)
      end
      expect(run_build(env, "Add a greeting", dir:)).to be(true)

      expect(out.string).to include("! not merged into main: #{dir} has uncommitted changes on main",
                                    "Done, but not everything was merged", "runeforge/add-a-greeting")
      expect(git(dir, "log", "--format=%s", "main..runeforge/add-a-greeting").lines.size).to eq(3) # plan, code, inbox folder
      expect(env.tasks.list.first[:merged_sha]).to be_nil
    end

    it "ends by saying how to run what it built" do
      plan = "#{plan_script}\nprintf '{\"test_command\": \"for t in test/*_test.sh; do sh $t || exit 1; done\", \"run_command\": \"cat lib/greeting.txt\", \"run_command_new\": true}' > .runeforge/project.json\n"
      code = "#{code_script}\nprintf '## How to run\\n\\n    cat lib/greeting.txt\\n' > README.md\n"
      env = build_env("agent" => { "command" => "sh #{fake_agent(plan:, code:)}" })
              .tap { |e| e.github = Helpers::FakeGitHub.new(opens_prs: false) }
      target = File.join(tmpdir, "greeter")
      expect(run_build(env, "Add a greeting", answers: "#{target}\n")).to be(true)

      expect(out.string).to include("Run it:\n  cd #{target}\n  cat lib/greeting.txt")
    end

    it "lists the steps and asks before building more than ten" do
      env = build_env_for
      plan = File.join(tmpdir, "long.md")
      File.write(plan, "# Big\n\n#{(1..12).map { |n| "- Add part #{n}\n" }.join}")
      expect { run_build(env, plan, answers: "n\n") }.to raise_error(Runeforge::Error, /stopped before building/)
      expect(out.string).to include("12 steps:", " 1. Add part 1", "12. Add part 12", "Build all 12 steps? [y/N]")
      expect(env.tasks.list).to be_empty
    end

    it "stops an Apple-platform request headed for the Linux sandbox, and says what to set" do
      env = build_env("sandbox" => { "mode" => "docker" })
      dir = make_project
      expect { run_build(env, "Build an iOS app with SwiftUI", dir:, answers: "n\n") }
        .to raise_error(Runeforge::Error, /stopped before building: build it on a machine with macOS with Xcode/)
      expect(out.string).to include("This looks like an Apple-platform app (iOS/macOS) (the request mentions iOS) needs macOS with Xcode",
                                    "projects: { #{dir}: { sandbox: none } }", "Continue anyway? [y/N]")
      expect(env.tasks.list).to be_empty
    end

    it "says to install Xcode when an Apple project runs on a Mac without it" do
      allow(Runeforge::Platform).to receive(:mac?).and_return(true)
      allow(Runeforge::Platform).to receive(:capture).and_return(["xcode-select: error: tool 'xcodebuild' requires Xcode", false])
      dir = make_project
      env = build_env("sandbox" => { "mode" => "docker" }, "projects" => { dir => { "sandbox" => "none" } })
      expect { run_build(env, "Build an iOS app", dir:, answers: "n\n") }.to raise_error(Runeforge::Error, /install the full Xcode app/)
      expect(out.string).to include("this machine (macOS, no Xcode (Command Line Tools only)), no sandbox")
    end

    it "marks the task platform_confirmed when the person builds anyway" do
      env = build_env("sandbox" => { "mode" => "docker" })
      runner = described_class.new(env, input: "Build an iOS app", stdin: StringIO.new("y\n"), stdout: out)
      runner.send(:platform_check!, nil)
      expect(runner.instance_variable_get(:@platform_confirmed)).to be(true)
    end

    it "runs a project set to sandbox: none on this machine while the default is Docker" do
      dir = make_project
      agent = fake_agent(plan: plan_script, code: code_script)
      env = build_env("sandbox" => { "mode" => "docker" }, "agent" => { "command" => "sh #{agent}" },
                      "projects" => { dir => { "sandbox" => "none" } })
      env.github = Helpers::FakeGitHub.new(opens_prs: false)
      allow(Runeforge::Platform).to receive_messages(mac?: true, xcode: Runeforge::Platform::Xcode.new(version: "Xcode 27.0", problem: nil, fix: nil))
      expect(run_build(env, "Add a greeting for the iOS app", dir:)).to be(true) # no Apple warning: it runs locally
      expect(File.read(File.join(dir, "lib", "greeting.txt"))).to eq("greeting\n")
      expect(out.string).not_to include("Apple-platform")
    end

    it "with manual_merge, creates the project and leaves it on the new branch" do
      env = build_env_for(manual_merge: true)
      target = File.join(tmpdir, "greeter")
      expect(run_build(env, "Add a greeting", answers: "#{target}\n")).to be(true)

      expect(out.string).to include("Directory for the new project [add-a-greeting]:", "✓ planned", "✓ tests passed", "Done.")
      expect(git(target, "branch", "--show-current").strip).to eq("runeforge/add-a-greeting")
      expect(File.read(File.join(target, "lib", "greeting.txt"))).to eq("greeting\n")
      expect(File.exist?(File.join(target, "test", "greeting_test.sh"))).to be(true)
      repo = env.repos.list.first
      expect(repo[:test_command]).to eq("for t in test/*_test.sh; do sh $t || exit 1; done")
    end

    it "with manual_merge, builds each unchecked task-list item in order on one branch" do
      env = build_env_for(manual_merge: true)
      plan = File.join(tmpdir, "plan.md")
      File.write(plan, "# Greeter\n\n- [x] Already done\n- Add a greeting\n- Add a farewell\n")
      target = File.join(tmpdir, "greeter")
      expect(run_build(env, plan, answers: "#{target}\n")).to be(true)

      expect(out.string).to include("Step 1/2: Add a greeting", "Step 2/2: Add a farewell")
      expect(git(target, "log", "--format=%s", "main..HEAD").lines.size).to eq(4) # plan + code per step
      expect(Dir.children(File.join(target, "lib")).sort).to eq(%w[farewell.txt greeting.txt])
      last = env.tasks.list.max_by { |task| task[:id] }
      expect(JSON.parse(last[:locked_paths]).keys).to contain_exactly("test/greeting_test.sh", "test/farewell_test.sh")
    end

    it "with manual_merge, works on a new branch in --dir and leaves the checkout alone" do
      env = build_env_for(manual_merge: true)
      dir = make_project
      expect(run_build(env, "Add a greeting", dir:)).to be(true)

      expect(git(dir, "branch", "--show-current").strip).to eq("main")
      expect(git(dir, "status", "--porcelain")).to be_empty
      expect(git(dir, "log", "--format=%s", "main..runeforge/add-a-greeting").lines.size).to eq(3) # plan, code, inbox folder
      expect(out.string).to include("Your checkout is unchanged", "git -C #{dir} switch runeforge/add-a-greeting")
    end

    it "with manual_merge, picks a fresh branch name when the previous one exists" do
      env = build_env_for(manual_merge: true)
      dir = make_project
      run_build(env, "Add a greeting", dir:)
      run_build(env, "Add a greeting", dir:)
      expect(git(dir, "branch", "--list", "runeforge/*").split).to contain_exactly("runeforge/add-a-greeting", "runeforge/add-a-greeting-2")
    end

    it "refuses to start when --dir has uncommitted changes" do
      env = build_env_for
      dir = make_project
      File.write(File.join(dir, "README.md"), "changed\n")
      File.write(File.join(dir, "notes.txt"), "new\n")

      expect { run_build(env, "Add a greeting", dir:) }
        .to raise_error(described_class::DirtyWorkingTree, /uncommitted changes:\n.*README.md\n.*notes.txt\nCommit or stash them/m)
      expect(env.tasks.list).to be_empty
    end

    it "offers to create a git repository in a plain directory" do
      env = build_env_for
      dir = File.join(tmpdir, "plain")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "notes.txt"), "x\n")

      expect { run_build(env, "Add a greeting", dir:, answers: "n\n") }.to raise_error(Runeforge::Error, /needs a git repository/)
      expect(run_build(env, "Add a greeting", dir:, answers: "y\n")).to be(true)
      expect(git(dir, "log", "--format=%s", "main").lines.map(&:strip).last).to eq("Initial commit")
      expect(File.read(File.join(dir, "lib", "greeting.txt"))).to eq("greeting\n")
    end

    it "asks for missing tools and stops if the person declines" do
      env = build_env_for(tools: '["runeforge-no-such-tool"]')
      target = File.join(tmpdir, "greeter")
      expect(run_build(env, "Add a greeting", answers: "#{target}\nn\n")).to be(false)

      expect(out.string).to include("Missing on this machine: runeforge-no-such-tool", "✗ stopped: missing runeforge-no-such-tool")
      expect(out.string).to include("Stopped: failed. missing tools: runeforge-no-such-tool")
    end

    it "rechecks after the person installs a missing tool the tests needed" do
      bin = File.join(tmpdir, "bin")
      FileUtils.mkdir_p(bin)
      original_path = ENV.fetch("PATH")
      ENV["PATH"] = "#{bin}:#{original_path}"
      env = build_env_for
      install = Object.new
      answers = ["#{File.join(tmpdir, 'greeter')}\n"]
      install.define_singleton_method(:gets) do
        next answers.shift unless answers.empty?

        File.write(File.join(bin, "rf-helper"), "#!/bin/sh\nexit 0\n")
        File.chmod(0o755, File.join(bin, "rf-helper"))
        "\n"
      end
      allow(Runeforge::Roles::Planner).to receive(:new).and_wrap_original do |original, *args|
        original.call(*args).tap do |planner|
          planner.define_singleton_method(:read_project) { |_ws| { "test_command" => "rf-helper && for t in test/*_test.sh; do sh $t || exit 1; done" } }
        end
      end

      expect(run_build(env, "Add a greeting", answers: install)).to be(true)
      expect(out.string).to include("✗ tests failed (exit status 127)", "· checking tools: rf-helper", "✓ tools available", "✓ tests passed")
    ensure
      ENV["PATH"] = original_path
    end
  end

  describe Runeforge::Operator do
    let(:backend) { "sqlite" }

    it "builds a per-project image with the packages the person confirms" do
      env = build_env("sandbox" => { "mode" => "docker" })
      add_repo(env)
      Runeforge::Tasks.new(db).create(id: "T-1", workflow: "build", repo: "demo", base_sha: "a" * 40, lane: "fg-1",
                                      mailbox: env.mailbox("cli"))
      installed = false
      checker = Object.new
      checker.define_singleton_method(:run) do |**|
        Runeforge::Sandbox::Result.new(exit_code: 0, stdout: installed ? "" : "cargo\n", stderr: "", timed_out: false)
      end
      env.sandbox_factory = ->(**) { checker }
      builds = []
      builder = lambda do |runtime, tag, dockerfile|
        builds << [runtime, tag, dockerfile]
        installed = true
      end
      output = StringIO.new
      msg = Runeforge::Message.new(id: 1, task_id: "T-1", type: "deps.check", recipient: "fg-1/operator", sender: "s",
                                   in_reply_to: nil, commit_sha: "b" * 40, payload: { "tools" => ["cargo", "bad;rm -rf /"], "resume" => "code" },
                                   state: "claimed", claimed_by: "x", lease_expires_at: nil, delivery_count: 1, last_error: nil, created_at: nil)

      outcome = described_class.new(env, input: StringIO.new("\n"), output:, builder:).call(msg)

      expect(outcome).to include(result_type: "deps.ready", commit_sha: "b" * 40)
      expect(outcome[:payload]).to eq("tools" => ["cargo"], "resume" => "code")
      expect(output.string).to include("missing: cargo", "Install these apt packages? [cargo]")
      expect(builds.first[0..1]).to eq(["docker", "runeforge/demo:latest"])
      expect(builds.first[2]).to include("FROM runeforge/general:latest", "apt-get install -y --no-install-recommends cargo")
      expect(env.repos.fetch("demo")[:image]).to eq("runeforge/demo:latest")
    end
  end

  describe "the command line" do
    def dispatch(*args)
      calls = []
      allow(Runeforge::Build).to receive(:new) { |_env, **kwargs| calls << kwargs; instance_double(Runeforge::Build, run: true) }
      allow(Runeforge::Environment).to receive(:load) { |**kwargs| calls << kwargs; instance_double(Runeforge::Environment) }
      Runeforge::CLI.start(args)
      calls
    end

    it "treats a bare prompt or file as the build command" do
      env_args, build_args = dispatch("Build me a thing")
      expect(build_args).to eq(input: "Build me a thing", dir: nil)
      expect(env_args[:database]).to be_nil
    end

    it "accepts -d for the directory and -db for the database, in any order" do
      env_args, build_args = dispatch("-db", "sqlite:///tmp/x.db", "plan.md", "-d", "proj")
      expect(build_args).to eq(input: "plan.md", dir: "proj")
      expect(env_args[:database]).to eq("sqlite:///tmp/x.db")

      _env, build_args = dispatch("-d", "proj", "plan.md")
      expect(build_args).to eq(input: "plan.md", dir: "proj")
    end
  end
end
