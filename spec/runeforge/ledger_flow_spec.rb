# frozen_string_literal: true

# The ledger as inbox plans run through it: items and claims, the brief, conflicts, work an agent
# found outside its step, and a step an earlier one already built.
RSpec.describe "The ledger across inbox steps" do
  on_each_backend do
    let(:origin) { make_origin }
    let(:clone) { File.join(tmpdir, "teammate") }
    let(:words) { "greeting|farewell" }
    let(:handoff) { "" }
    let(:code_handoff) { "" }

    let(:plan_script) do
      <<~SH
        word=$(sed -n '/^## This step/,$p' .runeforge/prompt.md | grep -o -m1 -E '#{words}')
        cp .runeforge/prompt.md "#{tmpdir}/prompt-$word.md"
        touch "#{tmpdir}/planned-$word"
        mkdir -p test
        printf 'Say %s.\\n' "$word" > .runeforge/spec.md
        printf 'grep -q %s lib/%s.txt\\n' "$word" "$word" > "test/${word}_test.sh"
        #{handoff}
      SH
    end
    # The coder writes its step's word, or every word when a step builds the next one too.
    let(:build_all) { false }
    let(:code_script) do
      <<~SH
        word=$(sed -n '/^## Spec/,$p' .runeforge/prompt.md | grep -o -m1 -E '#{words}')
        mkdir -p lib
        echo "$word" > "lib/$word.txt"
        #{build_all ? 'echo greeting > lib/greeting.txt; echo farewell > lib/farewell.txt' : ''}
        #{code_handoff}
      SH
    end

    def env_for
      build_env("agent" => { "command" => "sh #{fake_agent(plan: plan_script, code: code_script)}" }).tap { |env| add_repo(env, url: origin) }
    end

    def git(*args) = sh!("git", *args, dir: clone)

    def commit_plan(name, body)
      sh!("git", "clone", "-q", origin, clone, dir: tmpdir) unless File.directory?(clone)
      git("pull", "-q", "--no-rebase", "origin", "main")
      FileUtils.mkdir_p(File.join(clone, "runeforge/inbox"))
      File.write(File.join(clone, "runeforge/inbox", name), body)
      git("add", "-A")
      git("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "plan")
      git("push", "-q", "origin", "HEAD:main")
    end

    def plan(env, name) = env.db[:runeforge_plans].where(name:).order(:id).last

    def run_until(env, steps: 200)
      supervisor = Runeforge::Supervisor.new(env)
      worker = Runeforge::Worker.new(env, roles: Runeforge::Roles.names)
      steps.times do
        Runeforge::Inbox.new(env).poll_repo("demo")
        return if yield

        supervisor.tick
        worker.work_once
      end
      raise "stuck: #{env.db[:runeforge_plans].all.map { |p| [p[:name], p[:status], p[:reason]] }.inspect}"
    end

    PLAN = <<~MD
      # Two things

      - [ ] Add a greeting
        - The greeting is in `lib/greeting.txt`
      - [ ] Add a farewell
        - The farewell is in `lib/farewell.txt`
    MD

    def finished?(env, name) = %w[done failed].include?(plan(env, name)&.dig(:status))

    it "makes one ticket per item, claims each for its step, closes it at merge, and briefs the next planner" do
      env = env_for
      commit_plan("two.md", PLAN)
      run_until(env) { finished?(env, "two") }

      expect(plan(env, "two")).to include(status: "done", steps: 2)
      root = Runeforge::Ledger.root_id(plan(env, "two"))
      tickets = env.ledger.items.where(kind: "ticket").order(:position).all
      expect(tickets.map { |t| [t[:id], t[:status]] }).to eq([["#{root}.t1", "done"], ["#{root}.t2", "done"]])
      expect(tickets.map { |t| t[:task_id] }).to eq(env.tasks.list.sort_by { |t| t[:id] }.map { |t| t[:id] })
      expect(env.ledger.refs_for(["#{root}.t1"]).map { |r| r[:path] }).to include("lib/greeting.txt")
      expect(env.ledger.coverage_for(["#{root}.t1"]).map { |c| c[:test_path] }).to eq(["test/greeting_test.sh"])

      second = File.read(File.join(tmpdir, "prompt-farewell.md"))
      expect(second).to include("## Brief from earlier steps", "### This step's requirements", "- t2 Add a farewell",
                                "t2.r1 The farewell is in `lib/farewell.txt`", "## Handoff")
      expect(second).to include("### Code map").or include("### Tests that already pin nearby behaviour")
      # The step's text isn't repeated under "This step" when the whole request is shown.
      expect(second.scan("The farewell is in").size).to be >= 2
      expect(second[/## This step\n.*?\n\n/m]).to include("It is that item in the request above")
    end

    context "when the planner finds the step contradicts the project" do
      let(:handoff) do
        <<~SH
          cat > .runeforge/handoff.json <<'JSON'
          {"requirements": [{"id": "t1.r1", "status": "conflict", "cites": ["README.md:1", "README.md:99"]}]}
          JSON
          rm -rf test
        SH
      end

      it "stops the step for a decision instead of retrying or blaming the environment" do
        env = env_for
        commit_plan("two.md", PLAN)
        run_until(env) { finished?(env, "two") }

        task = env.tasks.list.first
        expect(task[:status]).to eq("failed")
        expect(task[:error]).to start_with("needs a decision: the step contradicts how the project works (README.md:1)")
        expect(env.tasks.messages(task[:id]).count { |m| m.type == "plan.request" }).to eq(1)
        failed = env.tasks.messages(task[:id]).find { |m| m.type == "plan.failed" }
        expect(Runeforge::Build.describe(failed, merging: true)).to start_with("⚠ needs a decision")
        expect(plan(env, "two")[:reason]).to include("needs a decision")
        expect(env.ledger.items.where(kind: "requirement", status: "conflict").count).to eq(1)
        expect(env.db[:runeforge_lessons].count).to eq(0)
      end
    end

    context "when the coder finds work outside its step" do
      let(:code_handoff) do
        <<~SH
          cat > .runeforge/handoff.json <<'JSON'
          {"implemented": [{"id": "t1.r1", "code": [{"path": "lib/greeting.txt", "note": "the greeting"}]}],
           "facts": [{"key": "texts", "kind": "layout", "text": "Texts live in lib/*.txt, one per word.", "paths": ["lib/greeting.txt"]}],
           "discovered": [{"title": "The README never mentions the texts", "why": "people can't find them", "evidence": "README.md:1"},
                          {"title": "Vague idea", "evidence": ""}]}
          JSON
        SH
      end

      it "queues it as an inbox plan after this one, keeps the coder's pointers and facts" do
        env = env_for
        commit_plan("two.md", "# One thing\n\n- [ ] Add a greeting\n  - The greeting is in `lib/greeting.txt`\n- [ ] Add a farewell\n  x\n")
        run_until(env) { plan(env, "two")&.dig(:step).to_i >= 1 || finished?(env, "two") }

        found = sh!("git", "ls-tree", "--name-only", "main", "runeforge/inbox/", dir: origin).split("\n").grep(/found-/)
        expect(found.size).to eq(1)
        body = sh!("git", "show", "main:#{found.first}", dir: origin)
        expect(body).to include("title: The README never mentions the texts", "after: two", "discovered_from: ", "Evidence: README.md:1")
        expect(Runeforge::PlanFile.parse(body).meta).to include("after" => ["two"])
        done = env.tasks.messages(env.tasks.list.min_by { |t| t[:id] }[:id]).find { |m| m.type == "integrate.done" }
        expect(Runeforge::Build.describe(done, merging: true)).to include("+ queued: The README never mentions the texts")
        expect(env.ledger.facts.where(key: "texts").first[:text]).to include("lib/*.txt")
        expect(env.ledger.refs.where(source: "handoff", path: "lib/greeting.txt").count).to eq(1)
      end
    end

    context "when a step builds the next one's requirements and says so" do
      let(:build_all) { true }
      let(:handoff) do
        <<~SH
          if [ "$word" = greeting ]; then
            printf 'grep -q farewell lib/farewell.txt\\n' > test/farewell_test.sh
            cat > .runeforge/handoff.json <<'JSON'
          {"requirements": [{"id": "t1.r1", "status": "new", "tests": ["test/greeting_test.sh"]},
                            {"id": "t2.r1", "status": "already_built", "tests": ["test/farewell_test.sh"]}]}
          JSON
          fi
        SH
      end

      it "merges the later step from the ledger without a planner session" do
        env = env_for
        commit_plan("two.md", PLAN)
        run_until(env) { finished?(env, "two") }

        expect(plan(env, "two")[:status]).to eq("done")
        expect(File.exist?(File.join(tmpdir, "planned-farewell"))).to be(false)
        second = env.tasks.list.max_by { |t| t[:id] }
        done = env.tasks.messages(second[:id]).find { |m| m.type == "plan.done" }
        expect(done.payload).to include("covered" => true)
        expect(done.payload["spec"]).to include("t2.r1", "test/farewell_test.sh")
        expect(Runeforge::Build.describe(done, merging: true)).to include("no planner needed")
        expect(env.ledger.find("#{Runeforge::Ledger.root_id(plan(env, 'two'))}.t2.r1")[:status]).to eq("already_built")
      end
    end
  end
end
