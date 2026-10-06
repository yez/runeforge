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

    it "takes manual_merge from the project's entry under projects" do
      env = build_env("agent" => { "command" => "sh #{fake_agent(plan: Helpers::PLAN_GREETING, code: Helpers::CODE_GREETING)}" },
                      "projects" => { origin => { "manual_merge" => true } })
      add_repo(env, url: origin)
      create(env)
      task = drive(env, "T-1", until_status: "done")
      expect(task[:merged_sha]).to be_nil
      expect(git("rev-parse", "runeforge/T-1").strip).to eq(task[:head_sha])

      env2 = env_with(code: Helpers::CODE_GREETING, manual_merge: true)
      env2.config.to_h["projects"] = { "demo" => { "manual_merge" => false } } # the repo's name works too
      Runeforge::Intake.new(env2).create(repo: "demo", id: "T-2", title: "Greet", description: "Say hello")
      expect(drive(env2, "T-2", until_status: "done")[:merged_sha]).to be_a(String)
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

    it "carries a long spec with emoji from the planner to the task" do
      plan = <<~SH
        mkdir -p test
        printf 'grep -q "Hello, Runeforge" lib/greeting.txt\\n' > test/greeting_test.sh
        { printf '## Greeting 🎉\\n\\nWhen it works, confetti ✨ falls.\\n'; for i in $(seq 1 40); do printf 'Detail line %s.\\n' "$i"; done; } > .runeforge/spec.md
      SH
      env = env_with(code: Helpers::CODE_GREETING, plan:)
      create(env)
      task = drive(env, "T-1", until_status: "done")

      expect(task[:spec]).to start_with("## Greeting 🎉\n\nWhen it works, confetti ✨ falls.")
      expect(task[:spec].bytesize).to be > 500
      plan_done = env.tasks.messages("T-1").find { |msg| msg.type == "plan.done" }
      expect(plan_done.payload["spec"]).to eq(task[:spec])
    end

    it "records how to run the project and sends the coder back until the README says so" do
      plan = <<~SH
        #{Helpers::PLAN_GREETING}
        printf '{"run_command": "cat lib/greeting.txt", "run_command_new": true}' > .runeforge/project.json
      SH
      code = <<~SH
        #{Helpers::CODE_GREETING}
        if grep -q "README.md" .runeforge/prompt.md && grep -q "Feedback from the previous attempt" .runeforge/prompt.md; then
          printf '# Greeting\\n\\n## How to run\\n\\n    cat lib/greeting.txt\\n' > README.md
        else
          printf '# Greeting\\n' > README.md
        fi
      SH
      env = env_with(code:, plan:)
      create(env)
      task = drive(env, "T-1", until_status: "done")

      expect(env.repos.fetch("demo")).to include(run_command: "cat lib/greeting.txt", run_docs_required: true)
      verdicts = env.tasks.messages("T-1").select { |msg| msg.type == "review.verdict" }
      expect(verdicts.map { |msg| msg.payload["approved"] }).to eq([false, true])
      expect(verdicts.first.payload["reasons"])
        .to eq(["README.md doesn't say how to run the project; its How to run section must include `cat lib/greeting.txt`"])
      expect(task[:attempts]).to eq(2)
      expect(git("show", "main:README.md")).to include("cat lib/greeting.txt")
    end

    it "keeps an existing project's own launch method and only notes a README that doesn't mention it" do
      plan = <<~SH
        #{Helpers::PLAN_GREETING}
        printf '{"run_command": "make run", "run_command_new": false}' > .runeforge/project.json
      SH
      env = env_with(code: Helpers::CODE_GREETING, plan:)
      create(env)
      task = drive(env, "T-1", until_status: "done")

      expect(task[:attempts]).to eq(1)
      expect(env.repos.fetch("demo")).to include(run_command: "make run", run_docs_required: false)
      verdict = env.tasks.messages("T-1").find { |msg| msg.type == "review.verdict" }
      expect(verdict.payload).to include("approved" => true, "reasons" => [])
      expect(verdict.payload["notes"]).to eq(["README.md doesn't say how to run the project; its How to run section must include `make run`"])
      expect(git("show", "main:README.md")).to eq("demo\n") # the project's own README was left alone
    end

    it "records the run command once, so later plans can't replace it" do
      env = env_with(code: Helpers::CODE_GREETING, plan: <<~SH)
        #{Helpers::PLAN_GREETING}
        printf '{"run_command": "npm start", "run_command_new": false}' > .runeforge/project.json
      SH
      create(env)
      drive(env, "T-1", until_status: "done")
      env.repos.update("demo", run_command: "foreman start") # what a person set with `runeforge repo set`

      second = <<~SH
        mkdir -p test
        printf 'Say bye.\\n' > .runeforge/spec.md
        printf 'true\\n' > test/bye_test.sh
        printf '{"run_command": "npm run dev", "run_command_new": true}' > .runeforge/project.json
      SH
      env2 = env_with(code: "mkdir -p lib && echo bye > lib/bye.txt", plan: second)
      Runeforge::Intake.new(env2).create(repo: "demo", id: "T-2", title: "Bye", description: "Say bye")
      drive(env2, "T-2", until_status: "done")
      expect(env2.repos.fetch("demo")).to include(run_command: "foreman start", run_docs_required: false)
    end

    it "accepts the run command documented in CONTRIBUTING.md or docs/" do
      plan = <<~SH
        #{Helpers::PLAN_GREETING}
        printf '{"run_command": "cat lib/greeting.txt", "run_command_new": true}' > .runeforge/project.json
      SH
      code = <<~SH
        #{Helpers::CODE_GREETING}
        mkdir -p docs && printf '# Running\\n\\nRun   cat   lib/greeting.txt\\n' > docs/running.md
      SH
      env = env_with(code:, plan:)
      create(env)
      task = drive(env, "T-1", until_status: "done")
      expect(task[:attempts]).to eq(1)
    end

    it "fails a plan whose test command doesn't run any tests" do
      plan = <<~SH
        #{Helpers::PLAN_GREETING}
        printf '{"test_command": "echo no tests ran; exit 5"}' > .runeforge/project.json
      SH
      env = env_with(code: Helpers::CODE_GREETING, plan:)
      env.repos.update("demo", test_command: "")
      create(env)
      task = drive(env, "T-1", until_status: "failed")
      expect(task[:error]).to include("planning failed: the test command `echo no tests ran; exit 5` didn't run the " \
                                      "acceptance tests (pytest found no tests)")
      expect(task[:attempts]).to eq(0)
    end

    it "rejects acceptance tests that read .runeforge/" do
      plan = <<~SH
        mkdir -p test
        printf 'Say hello.\\n' > .runeforge/spec.md
        printf 'grep -q hello .runeforge/project.json\\n' > test/greeting_test.sh
      SH
      env = env_with(code: Helpers::CODE_GREETING, plan:)
      create(env)
      task = drive(env, "T-1", until_status: "failed")
      expect(task[:error]).to include("acceptance tests test/greeting_test.sh read .runeforge/, which Runeforge never commits")
    end

    it "fails planning with the agent's reason when the stack can't be built here" do
      plan = "printf 'This is an iOS app: it needs Xcode on a Mac.\\n' > .runeforge/blocked.md\n"
      env = env_with(code: Helpers::CODE_GREETING, plan:)
      create(env)
      task = drive(env, "T-1", until_status: "failed")
      expect(task[:error]).to include("planning failed: the planner can't build this here: This is an iOS app: it needs Xcode on a Mac.")
    end

    it "sends a rejected plan back to the planner once with the reason, and continues when it's fixed" do
      plan = <<~SH
        if [ ! -f #{tmpdir}/planned ]; then
          touch #{tmpdir}/planned
          mkdir -p Sources && printf 'x\\n' > Sources/App.swift
          printf 'spec\\n' > .runeforge/spec.md
        else
          printf '%s' "$RUNEFORGE_PROMPT" > #{tmpdir}/second-prompt.md
          #{Helpers::PLAN_GREETING.gsub("\n", "\n  ")}
        fi
      SH
      env = env_with(code: Helpers::CODE_GREETING, plan:)
      create(env)
      task = drive(env, "T-1", until_status: "done")

      expect(env.tasks.messages("T-1").map(&:type).grep(/\Aplan\./)).to eq(%w[plan.request plan.failed plan.request plan.done])
      expect(File.read(File.join(tmpdir, "second-prompt.md")))
        .to include("## Your previous plan was rejected", "none of the changed files (Sources/App.swift) match test_globs")
      expect(task[:status]).to eq("done")
    end

    it "fails after the planner's second rejected plan" do
      plan = "mkdir -p Sources\nprintf 'spec\\n' > .runeforge/spec.md\nprintf 'x\\n' > Sources/App.swift\n"
      env = env_with(code: Helpers::CODE_GREETING, plan:)
      create(env)
      task = drive(env, "T-1", until_status: "failed")
      expect(env.tasks.messages("T-1").count { |m| m.type == "plan.request" }).to eq(2)
      expect(task[:error]).to start_with("planning failed: the plan has no acceptance tests")
    end

    it "names the changed files when the plan has no acceptance tests" do
      plan = "mkdir -p Sources\nprintf 'spec\\n' > .runeforge/spec.md\nprintf 'x\\n' > Sources/App.swift\n"
      env = env_with(code: Helpers::CODE_GREETING, plan:)
      create(env)
      task = drive(env, "T-1", until_status: "failed")
      expect(task[:error]).to include("the plan has no acceptance tests: none of the changed files (Sources/App.swift) match test_globs")
    end

    it "stops a platform app before the planner's agent runs when this machine can't build it, and records why" do
      allow(Runeforge::Platform).to receive(:mac?).and_return(false)
      env = env_with(code: Helpers::CODE_GREETING)
      Runeforge::Intake.new(env).create(repo: "demo", id: "T-1", title: "Build an iOS app", description: "With SwiftUI")
      task = drive(env, "T-1", until_status: "failed")

      expect(task[:error]).to include("incompatible build environment: an Apple-platform app (iOS/macOS) (the request mentions iOS) " \
                                      "needs macOS with Xcode", "To fix: build it on a Mac with Xcode")
      expect(task[:tokens_used].to_i).to eq(0)
      expect(env.repos.fetch("demo")).to include(platform: "apple", platform_status: "incompatible")
      expect(env.repos.fetch("demo")[:platform_note]).to include("To fix: build it on a Mac with Xcode")
    end

    it "records a portable project as compatible" do
      env = env_with(code: Helpers::CODE_GREETING)
      create(env)
      drive(env, "T-1", until_status: "done")
      expect(env.repos.fetch("demo")).to include(platform: nil, platform_status: "compatible", platform_note: "a portable project")
    end

    it "plans again, then stops, when the coder keeps committing nothing after the tests failed" do
      code = <<~SH
        if [ ! -f #{tmpdir}/first ]; then touch #{tmpdir}/first; mkdir -p lib; echo wrong > lib/greeting.txt; else mkdir -p .runeforge; echo '{}' > .runeforge/project.json; fi
      SH
      env = env_with(code:)
      create(env)
      task = drive(env, "T-1", until_status: "failed")

      # One real attempt and two with nothing to commit; then the planner is asked again with the
      # coder's report, and two more attempts with nothing to commit end the task.
      requests = env.tasks.messages("T-1").select { |m| m.type == "plan.request" }
      expect(requests.map { |m| m.payload["replan"] }).to eq([nil, true])
      expect(requests.last.payload["feedback"]).to include("The coder couldn't make your acceptance tests pass", "FAIL test/greeting_test.sh")
      expect(task[:attempts]).to eq(2) # attempts start again for the new plan
      expect(task[:error]).to include("the coder changed nothing on its last 2 attempts after the tests failed",
                                      "FAIL test/greeting_test.sh")
      reasons = env.tasks.messages("T-1").select { |m| m.type == "code.failed" }.map { |m| m.payload["reason"] }
      expect(reasons).to all(eq("the agent only changed files in .runeforge/ (project.json), which Runeforge never commits; " \
                                "the tests and code must not depend on them"))
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
