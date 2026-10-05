# frozen_string_literal: true

RSpec.describe Runeforge::Inbox do
  on_each_backend do
    let(:origin) { make_origin }
    let(:clone) { File.join(tmpdir, "teammate") }
    let(:words) { "greeting|farewell|welcome|thanks" }

    # Planner: a test for the first word of the request. Coder: lib/<word>.txt to pass it.
    let(:plan_script) do
      <<~SH
        word=$(sed -n '/^## This step/,$p;/^## The request/,$p' .runeforge/prompt.md | grep -o -m1 -E '#{words}')
        mkdir -p test
        printf 'Say %s.\\n' "$word" > .runeforge/spec.md
        printf 'grep -q %s lib/%s.txt\\n' "$word" "$word" > "test/${word}_test.sh"
      SH
    end
    let(:code_script) do
      <<~SH
        word=$(sed -n '/^## Spec/,$p' .runeforge/prompt.md | grep -o -m1 -E '#{words}')
        mkdir -p lib
        echo "$word" > "lib/${word}.txt"
      SH
    end

    def inbox_env(manual_merge: false, code: code_script)
      build_env("agent" => { "command" => "sh #{fake_agent(plan: plan_script, code:)}" }, "manual_merge" => manual_merge)
        .tap { |env| add_repo(env, url: origin) }
    end

    def git(*args, dir: clone) = sh!("git", *args, dir:)

    def commit_plans(files, message: "plans", delete: [])
      sh!("git", "clone", "-q", origin, clone, dir: tmpdir) unless File.directory?(clone)
      git("pull", "-q", "--no-rebase", "origin", "main")
      files.each do |path, body|
        file = File.join(clone, "runeforge/inbox", path)
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, body)
      end
      delete.each { |path| git("rm", "-q", "runeforge/inbox/#{path}") }
      git("add", "-A")
      git("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", message)
      git("push", "-q", "origin", "HEAD:main")
    end

    def rename_plan(from, to)
      git("pull", "-q", "--no-rebase", "origin", "main")
      git("mv", "runeforge/inbox/#{from}", "runeforge/inbox/#{to}")
      git("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "rename")
      git("push", "-q", "origin", "HEAD:main")
    end

    def inbox(env) = described_class.new(env)

    def plans(env) = env.db[:runeforge_plans].order(:id).all

    def plan(env, name) = plans(env).reject { |p| p[:status] == "superseded" }.select { |p| p[:name] == name }.max_by { |p| p[:id] }

    # Polls the inbox and runs the supervisor and an all-roles worker until `done` is true.
    def run_until(env, steps: 200)
      supervisor = Runeforge::Supervisor.new(env)
      worker = Runeforge::Worker.new(env, roles: Runeforge::Roles.names)
      steps.times do
        inbox(env).poll_repo("demo")
        return if yield

        supervisor.tick
        worker.work_once
      end
      raise "inbox stuck: #{plans(env).map { |p| [p[:name], p[:status], p[:reason]] }.inspect}"
    end

    def origin_file(path) = sh!("git", "show", "main:#{path}", dir: origin)

    def origin_files(dir) = sh!("git", "ls-tree", "--name-only", "main", "#{dir}/", dir: origin).split("\n")

    it "builds plans in the order they arrived, not by file name, and moves them to done/" do
      env = inbox_env
      commit_plans({ "zz-first.md" => "# Add a greeting\n" }, message: "first")
      commit_plans({ "aa-second.md" => "# Add a farewell\n" }, message: "second")
      run_until(env) { plans(env).all? { |p| p[:status] == "done" } && plans(env).size == 2 }

      tasks = env.tasks.list.sort_by { |t| t[:created_at] }
      expect(tasks.map { |t| t[:title] }).to eq(["Add a greeting", "Add a farewell"])
      expect(tasks.map { |t| t[:workflow] }.uniq).to eq(["inbox"])
      expect(origin_file("lib/greeting.txt")).to eq("greeting\n")
      expect(origin_file("lib/farewell.txt")).to eq("farewell\n")
      expect(origin_files("runeforge/inbox")).to eq(["runeforge/inbox/.gitkeep"]).or eq([])
      record = origin_file("runeforge/done/zz-first.md")
      expect(record).to start_with("# Add a greeting\n").and include("Built by Runeforge", "`#{tasks.first[:id]}`")
      # The second plan carries the first plan's locked test.
      expect(JSON.parse(tasks.last[:locked_paths]).keys).to include("test/greeting_test.sh", "test/farewell_test.sh")
      expect(env.db[:runeforge_events].where(kind: "plan.done").count).to eq(2)
    end

    it "orders by the commit that added each plan, following renames" do
      env = inbox_env
      commit_plans({ "b.md" => "# Add a greeting\n" }, message: "b")
      commit_plans({ "a.md" => "# Add a farewell\n" }, message: "a")
      rename_plan("b.md", "c.md")
      base = env.repos.refresh("demo")
      entries = inbox(env).scan("demo", base)

      expect(entries.keys).to contain_exactly("runeforge/inbox/a.md", "runeforge/inbox/c.md")
      expect(entries["runeforge/inbox/c.md"][:arrival]).to be < entries["runeforge/inbox/a.md"][:arrival]
      expect(entries["runeforge/inbox/c.md"][:updated]).to be > entries["runeforge/inbox/a.md"][:updated]
    end

    it "runs a task list one merged step at a time" do
      env = inbox_env
      commit_plans({ "two.md" => "# Two things\n\n- [x] Already done\n- Add a greeting\n- Add a farewell\n" })
      run_until(env) { plan(env, "two")&.dig(:status) == "done" }

      tasks = env.tasks.list.sort_by { |t| t[:id] }
      expect(tasks.map { |t| t[:branch] }).to all(start_with("runeforge/two-p"))
      expect(tasks.map { |t| t[:merged_sha] }).to all(be_a(String))
      expect(tasks.last[:base_sha]).to eq(tasks.first[:merged_sha])
      expect(plan(env, "two")).to include(step: 2, steps: 2)
    end

    it "keeps an edited queued plan's place and restarts an edited running plan" do
      env = inbox_env
      commit_plans({ "one.md" => "# Add a greeting\n" }, message: "one")
      commit_plans({ "two.md" => "# Add a farewell\n" }, message: "two")
      inbox(env).poll_repo("demo")
      expect(plan(env, "one")[:status]).to eq("running")
      first_task = plan(env, "one")[:task_id]

      commit_plans({ "two.md" => "# Add a farewell, warmly\n", "one.md" => "# Add a welcome\n" }, message: "edits")
      inbox(env).poll_repo("demo")

      expect(env.tasks.find(first_task)[:status]).to eq("cancelled")
      one = plan(env, "one")
      expect(one[:status]).to eq("running")
      expect(one[:task_id]).not_to eq(first_task)
      expect(plan(env, "two")).to include(status: "queued", title: "Add a farewell, warmly")
      expect(plan(env, "two")[:arrival]).to be > one[:arrival]
      expect(env.db[:runeforge_plans].where(status: "superseded").count).to eq(2)
    end

    it "drops a deleted queued plan and cancels a deleted running one" do
      env = inbox_env
      commit_plans({ "one.md" => "# Add a greeting\n", "two.md" => "# Add a farewell\n" })
      inbox(env).poll_repo("demo")
      running = plan(env, "one")
      commit_plans({}, delete: %w[one.md two.md], message: "never mind")
      inbox(env).poll_repo("demo")

      expect(plan(env, "one")[:status]).to eq("cancelled")
      expect(env.tasks.find(running[:task_id])[:status]).to eq("cancelled")
      expect(plan(env, "two")).to include(status: "dropped", reason: "removed from the inbox")
    end

    it "holds a plan back until the plan named in after: is done" do
      env = inbox_env
      commit_plans({ "export.md" => "---\nafter: reports\n---\n# Add a farewell\n" }, message: "export")
      commit_plans({ "other.md" => "# Add a welcome\n" }, message: "other")
      inbox(env).poll_repo("demo")
      expect(plan(env, "export")).to include(status: "blocked", reason: "waiting on reports")
      expect(plan(env, "other")[:status]).to eq("running")

      commit_plans({ "reports.md" => "# Add a greeting\n" }, message: "reports")
      run_until(env) { plans(env).count { |p| p[:status] == "done" } == 3 }
      order = env.tasks.list.sort_by { |t| t[:created_at] }.map { |t| t[:title] }
      expect(order).to eq(["Add a welcome", "Add a greeting", "Add a farewell"])
    end

    it "pauses the queue when a plan's work isn't merged, and resumes once it lands" do
      env = inbox_env
      original = env.repos.method(:merge)
      refusals = 0
      allow(env.repos).to receive(:merge) do |*args, **kwargs|
        refusals += 1
        raise Runeforge::RepoStore::MergeBlocked, "simulated branch protection" if refusals == 1

        original.call(*args, **kwargs)
      end
      commit_plans({ "one.md" => "# Add a greeting\n" }, message: "one")
      commit_plans({ "two.md" => "# Add a farewell\n" }, message: "two")
      run_until(env) { plan(env, "one")[:status] == "unmerged" }
      inbox(env).poll_repo("demo")

      branch = env.tasks.find(plan(env, "one")[:task_id])[:branch]
      expect(plan(env, "one")[:reason]).to include("not merged into main", branch)
      expect(plan(env, "two")).to include(status: "blocked", reason: "waiting for one to be merged")

      # A person merges the branch.
      git("pull", "-q", "--no-rebase", "origin", "main")
      git("fetch", "-q", "origin", branch)
      git("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "merge", "-q", "--no-edit", "FETCH_HEAD")
      git("push", "-q", "origin", "HEAD:main")
      run_until(env) { plan(env, "two")[:status] == "done" }

      expect(plan(env, "one")[:status]).to eq("done")
      expect(origin_file("lib/farewell.txt")).to eq("farewell\n")
    end

    it "lets replaces: unlock an earlier plan's acceptance tests" do
      env = inbox_env
      commit_plans({ "hello.md" => "# Add a greeting\n" }, message: "hello")
      run_until(env) { plan(env, "hello")&.dig(:status) == "done" }
      expect(JSON.parse(plan(env, "hello")[:locked])).to eq(["test/greeting_test.sh"])

      commit_plans({ "redo.md" => "---\nreplaces: hello\n---\n# Add a farewell\n" }, message: "redo")
      inbox(env).poll_repo("demo")
      task = env.tasks.find(plan(env, "redo")[:task_id])
      expect(JSON.parse(task[:locked_paths])).to be_empty
    end

    it "tells the planner about the plans still queued" do
      env = inbox_env
      commit_plans({ "one.md" => "# Add a greeting\n" }, message: "one")
      commit_plans({ "two.md" => "# Add a farewell\n" }, message: "two")
      inbox(env).poll_repo("demo")
      created = env.tasks.messages(plan(env, "one")[:task_id]).first
      expect(created.payload["queued"]).to eq(["Add a farewell (two)"])
      prompt = Runeforge::Prompts.plan(task: env.tasks.find(plan(env, "one")[:task_id]), input: created.payload,
                                       test_globs: ["test/**/*"], test_command: "sh test/run.sh")
      expect(prompt).to include("## Plans queued after this one", "- Add a farewell (two)", "under `runeforge/`")
    end

    it "fails a plan whose front matter is broken without blocking the rest" do
      env = inbox_env
      commit_plans({ "bad.md" => "---\nafter: [\n---\n# Add a greeting\n" }, message: "bad")
      commit_plans({ "good.md" => "# Add a farewell\n" }, message: "good")
      inbox(env).poll_repo("demo")
      expect(plan(env, "bad")).to include(status: "failed")
      expect(plan(env, "bad")[:reason]).to include("front matter is not valid YAML")
      expect(plan(env, "good")[:status]).to eq("running")
    end

    it "lists the queue with runeforge inbox" do
      env = inbox_env
      commit_plans({ "export.md" => "---\nafter: reports\n---\n# Add a farewell\n" }, message: "export")
      commit_plans({ "other.md" => "# Add a welcome\n" }, message: "other")
      next unless backend == "sqlite"

      # Point the CLI at this spec's home and database, never ~/.runeforge.
      config = File.join(tmpdir, "runeforge.yml")
      File.write(config, YAML.dump("home" => env.home, "database" => "sqlite://#{File.join(tmpdir, 'test.db')}"))
      out = StringIO.new
      original = $stdout
      $stdout = out
      begin
        Runeforge::CLI.start(["inbox", "--poll", "--config", config])
      rescue SystemExit
        nil # Thor exits on errors; the output below says why
      end
      $stdout = original

      lines = out.string.lines.map(&:rstrip)
      expect(lines.first).to eq("demo")
      expect(lines.join("\n")).to match(/other\s+running\s+1\/1\s+other-p\d+/).and match(/export\s+blocked\s+-\s+-\s+waiting on reports/)
    ensure
      $stdout = original if original
    end

    context "with manual_merge" do
      it "stacks plans on one shared branch and starts it over once everything has landed" do
        env = inbox_env(manual_merge: true)
        commit_plans({ "one.md" => "# Add a greeting\n" }, message: "one")
        commit_plans({ "two.md" => "# Add a farewell\n" }, message: "two")
        run_until(env) { plans(env).count { |p| p[:status] == "done" } == 2 }

        tasks = env.tasks.list.sort_by { |t| t[:created_at] }
        expect(tasks.map { |t| t[:branch] }.uniq).to eq(["runeforge/inbox"])
        expect(tasks.last[:base_sha]).to eq(tasks.first[:head_sha])
        expect(tasks.map { |t| t[:merged_sha] }).to all(be_nil)
        expect(origin_files("runeforge/inbox")).to include("runeforge/inbox/one.md") # nothing merged yet

        # A person merges the shared branch; the next plan starts from main again.
        git("pull", "-q", "--no-rebase", "origin", "main")
        git("fetch", "-q", "origin", "runeforge/inbox")
        git("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "merge", "-q", "--no-edit", "FETCH_HEAD")
        git("push", "-q", "origin", "HEAD:main")
        commit_plans({ "three.md" => "# Add a welcome\n" }, message: "three")
        main = sh!("git", "rev-parse", "main", dir: origin).strip
        inbox(env).poll_repo("demo")

        third = env.tasks.find(plan(env, "three")[:task_id])
        expect(third[:base_sha]).to eq(main)
        expect(origin_files("runeforge/inbox")).not_to include("runeforge/inbox/one.md")
      end
    end
  end

  describe "protecting runeforge/" do
    let(:backend) { "sqlite" }

    it "rejects an agent patch that touches the inbox" do
      env = build_env
      add_repo(env)
      committer = env.committer("demo")
      base = env.repos.refresh("demo")
      patch = <<~PATCH
        diff --git a/runeforge/inbox/x.md b/runeforge/inbox/x.md
        new file mode 100644
        --- /dev/null
        +++ b/runeforge/inbox/x.md
        @@ -0,0 +1 @@
        +- [x] mark my own plan done
      PATCH
      expect { committer.commit(patch:, parent: base, branch: "runeforge/t", message: "m") }
        .to raise_error(Runeforge::Committer::PatchRejected, %r{patch touches runeforge/: runeforge/inbox/x.md})
    end
  end
end
