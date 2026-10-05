# frozen_string_literal: true

RSpec.describe "Ticket to pull request" do
  on_each_backend do
    let(:origin) { make_origin }

    def env_with(code:, plan: Helpers::PLAN_GREETING, max_attempts: 5, manual_merge: false)
      build_env("agent" => { "command" => "sh #{fake_agent(plan:, code:)}" }, "budgets" => { "max_attempts" => max_attempts },
                "manual_merge" => manual_merge)
        .tap { |env| add_repo(env, url: origin) }
    end

    def create(env) = Runeforge::Intake.new(env).create(repo: "demo", id: "T-1", title: "Greet", description: "Say hello")

    def git(*args) = sh!("git", *args, dir: origin)

    it "plans, codes, tests, then merges the work into the base branch" do
      env = env_with(code: Helpers::CODE_GREETING)
      create(env)
      task = drive(env, "T-1", until_status: "done")

      expect(task[:merged_sha]).to eq(git("rev-parse", "main").strip)
      expect(git("show", "main:lib/greeting.txt")).to eq("Hello, Runeforge\n")
      # Nothing else landed on main meanwhile, so it's a fast-forward and the trailers survive.
      expect(task[:merged_sha]).to eq(task[:head_sha])
      expect(git("log", "-1", "--format=%B", "main")).to include("Agent-Task: T-1")
      expect(git("branch", "--list", "runeforge/*")).to be_empty
      done = env.tasks.messages("T-1").find { |msg| msg.type == "integrate.done" }
      expect(done.payload).to include("merged" => true, "base" => "main", "warnings" => [])
    end

    # Someone else commits to main after the task was created.
    def push_from_elsewhere(path, body, message)
      clone = File.join(tmpdir, "other")
      sh!("git", "clone", "-q", origin, clone, dir: tmpdir) unless File.directory?(clone)
      FileUtils.mkdir_p(File.dirname(File.join(clone, path)))
      File.write(File.join(clone, path), body)
      sh!("git", "add", "-A", dir: clone)
      sh!("git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", message, dir: clone)
      sh!("git", "push", "-q", "origin", "main", dir: clone)
      sh!("git", "rev-parse", "HEAD", dir: clone).strip
    end

    it "makes a merge commit when the base branch moved on" do
      env = env_with(code: Helpers::CODE_GREETING)
      create(env)
      other = push_from_elsewhere("NOTES.md", "meanwhile\n", "meanwhile")
      task = drive(env, "T-1", until_status: "done")

      expect(git("rev-parse", "main").strip).to eq(task[:merged_sha])
      expect(git("log", "-1", "--format=%P", "main").split).to contain_exactly(task[:head_sha], other)
      expect(git("log", "-1", "--format=%B", "main")).to start_with("Merge runeforge/T-1: Greet").and include("Agent-Task: T-1")
      expect(git("show", "main:NOTES.md")).to eq("meanwhile\n")
    end

    it "leaves a conflicting branch for a person, and still finishes the task" do
      env = env_with(code: Helpers::CODE_GREETING)
      create(env)
      push_from_elsewhere("lib/greeting.txt", "Howdy\n", "howdy")
      task = drive(env, "T-1", until_status: "done")

      expect(task[:merged_sha]).to be_nil
      warning = env.tasks.messages("T-1").find { |msg| msg.type == "integrate.done" }.payload["warnings"].first
      expect(warning).to include("not merged into main: it conflicts with main", "the work is on runeforge/T-1")
      expect(git("show", "main:lib/greeting.txt")).to eq("Howdy\n")
      expect(git("rev-parse", "runeforge/T-1").strip).to eq(task[:head_sha])
    end

    it "with manual_merge, pushes the branch and opens a PR without merging" do
      env = env_with(code: Helpers::CODE_GREETING, manual_merge: true)
      create(env)
      task = drive(env, "T-1", until_status: "done")

      expect(task[:external_pr_url]).to eq("https://github.com/acme/demo/pull/1")
      expect(env.github.calls.first).to include(head: "runeforge/T-1", base: "main")
      expect(git("rev-parse", "runeforge/T-1").strip).to eq(task[:head_sha])
      expect(git("show", "#{task[:head_sha]}:lib/greeting.txt")).to eq("Hello, Runeforge\n")
      # The first task in a repository also adds the runeforge/ inbox folder.
      expect(git("log", "--format=%s", "main..runeforge/T-1").lines.map(&:strip))
        .to eq(["runeforge: add the inbox folder", "runeforge: attempt 1 for T-1", "runeforge: plan for T-1"])
      expect(git("log", "-1", "--format=%B", "runeforge/T-1~1")).to include("Agent-Task: T-1", "Agent-Attempt: 1", "Agent-Model: command")
      expect(JSON.parse(task[:locked_paths]).keys).to eq(["test/greeting_test.sh"])
      expect(task[:spec]).to eq("Say hello to Runeforge.\n")
      expect(task).to include(tokens_used: 240, cost_cents: 2, attempts: 1)
    end

    it "keeps installed dependencies and caches out of the coder's patch" do
      code = <<~SH
        #{Helpers::CODE_GREETING}
        mkdir -p node_modules/left-pad .venv/lib __pycache__
        echo x > node_modules/left-pad/index.js
        echo x > .venv/lib/site.py
        echo x > __pycache__/greeting.cpython-311.pyc
      SH
      env = env_with(code:)
      create(env)
      task = drive(env, "T-1", until_status: "done")
      code_done = env.tasks.messages("T-1").find { |msg| msg.type == "code.done" }
      expect(code_done.payload["changed_paths"]).to eq(["lib/greeting.txt"])
      expect(git("ls-tree", "-r", "--name-only", task[:head_sha])).not_to include("node_modules", ".venv", "__pycache__")
    end

    it "feeds test failures back to the coder and passes on the next attempt" do
      code = <<~SH
        mkdir -p lib
        if grep -q "Feedback from the previous attempt" .runeforge/prompt.md; then
          printf 'Hello, Runeforge\\n' > lib/greeting.txt
        else
          printf 'Goodbye\\n' > lib/greeting.txt
        fi
      SH
      env = env_with(code:)
      create(env)
      task = drive(env, "T-1", until_status: "done")

      expect(task[:attempts]).to eq(2)
      results = env.tasks.messages("T-1").select { |msg| msg.type == "test.result" }
      expect(results.map { |msg| msg.payload["passed"] }).to eq([false, true])
      expect(results.first.payload["output_tail"]).to include("FAIL test/greeting_test.sh")
    end

    it "rejects attempts that edit the locked tests and fails at the attempt limit" do
      code = <<~SH
        printf 'true\\n' > test/greeting_test.sh
        #{Helpers::CODE_GREETING}
      SH
      env = env_with(code:, max_attempts: 2)
      create(env)
      task = drive(env, "T-1", until_status: "failed")

      expect(task[:error]).to include("attempt limit reached (2/2)", "locked test files: test/greeting_test.sh")
      expect(git("branch", "--list", "runeforge/*")).to be_empty
    end

    it "lets the planner add scaffolding but only locks test files" do
      env = env_with(plan: "#{Helpers::PLAN_GREETING}\nprintf 'x' > setup.cfg", code: Helpers::CODE_GREETING)
      create(env)
      task = drive(env, "T-1", until_status: "done")
      expect(JSON.parse(task[:locked_paths]).keys).to eq(["test/greeting_test.sh"])
      expect(git("show", "#{task[:head_sha]}:setup.cfg")).to eq("x")
    end

    it "fails a plan that has no acceptance tests" do
      env = env_with(plan: "printf 'x' > setup.cfg", code: Helpers::CODE_GREETING)
      create(env)
      task = drive(env, "T-1", until_status: "failed")
      expect(task[:error]).to include("planning failed", "the plan has no acceptance tests")
    end

    it "restarts from an earlier message when a person grants another attempt" do
      code = <<~SH
        mkdir -p lib
        if [ -f #{tmpdir}/fixed ]; then printf 'Hello, Runeforge\\n'; else printf 'nope\\n'; fi > lib/greeting.txt
      SH
      env = env_with(code:, max_attempts: 1)
      create(env)
      drive(env, "T-1", until_status: "failed")

      FileUtils.touch(File.join(tmpdir, "fixed"))
      plan_done = env.tasks.messages("T-1").find { |msg| msg.type == "plan.done" }
      env.tasks.retry_from("T-1", message_id: plan_done.id, add_attempts: 1, mailbox: env.mailbox("cli"))
      task = drive(env, "T-1", until_status: "done")

      expect(task[:attempts]).to eq(2)
      retried = env.tasks.messages("T-1").select { |msg| msg.type == "code.done" }.last
      expect(Runeforge::Git.run("show", "#{retried.commit_sha}^", "--format=%H", "--no-patch", dir: env.repos.path("demo")).strip)
        .to eq(plan_done.commit_sha)
    end
  end
end
