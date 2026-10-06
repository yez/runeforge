# frozen_string_literal: true

RSpec.describe Runeforge::BuildProgress do
  let(:backend) { "sqlite" }
  let(:plan_text) do
    <<~MD
      # Demo

      ### Step 1: Setup
      Make the project.

      ### Step 2: Model
      Add the model.

      ### Step 3: Engine
      Add the engine.

      ### Step 4: UI
      Add the UI.
    MD
  end
  let(:plan) { Runeforge::PlanFile.parse(plan_text) }
  let(:origin) { File.join(tmpdir, "proj") }
  let(:env) { build_env("manual_merge" => manual_merge) }
  let(:manual_merge) { false }
  let(:progress) { described_class.new(env, "proj") }
  let!(:base0) do
    FileUtils.mkdir_p(origin)
    git(origin, "init", "-q", "-b", "main")
    commit(origin, { "README.md" => "x" }, "init").tap do
      env.repos.add(name: "proj", url: origin, test_command: "true", base_branch: "main")
    end
  end

  def git(dir, *args) = sh!("git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *args, dir:)

  def commit(dir, files, message)
    files.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      File.write(File.join(dir, path), body)
    end
    git(dir, "add", "-A")
    git(dir, "commit", "-qm", message)
    git(dir, "rev-parse", "HEAD").strip
  end

  # A build task for `step`, as Build creates it, then moved to the given state.
  def add_task(id, step, status:, base:, head: nil, merged: nil, locked: {}, lane: "fg-aaaa", age: 3600, branch: nil)
    input = { "title" => step.title, "description" => step.body, "context" => plan.text, "step_key" => step.key,
              "plan" => { "text" => plan_text, "list" => true, "source" => "spec" } }
    env.tasks.create(id:, workflow: "build", repo: "proj", base_sha: base, mailbox: env.mailbox("cli"), input:, lane:,
                     branch: branch || "runeforge/#{id}", title: step.title)
    env.db[:runeforge_tasks].where(id:).update(status:, head_sha: head, merged_sha: merged, locked_paths: JSON.generate(locked),
                                               created_at: Runeforge.now - age, updated_at: Runeforge.now - age)
  end

  def oid(sha, path) = env.repos.oid("proj", sha, path)

  context "with merging" do
    let!(:shas) do
      c1 = commit(origin, { "Tests/OneTests.swift" => "1" }, "step 1")
      c2 = commit(origin, { "Tests/TwoTests.swift" => "2" }, "step 2")
      commit(origin, { "Tests/OneTests.swift" => "1, changed by a person" }, "a person edits step 1's test")
      add_task("demo-aaaa-s1", plan.steps[0], status: "done", base: base0, head: c1, merged: c1, locked: { "Tests/OneTests.swift" => "old" })
      add_task("demo-aaaa-s2", plan.steps[1], status: "done", base: c1, head: c2, merged: c2,
                                              locked: { "Tests/OneTests.swift" => "old", "Tests/TwoTests.swift" => "old" })
      add_task("demo-aaaa-s3", plan.steps[2], status: "failed", base: c2, head: c2)
      [c1, c2]
    end
    let(:base) { env.repos.refresh("proj") }

    it "skips the done steps at the start, locking their tests as they are at the base" do
      start = progress.start(plan, base:)
      expect(start).to have_attributes(skip: 2, base:, branch: nil)
      expect(start.done.map { |task| task[:id] }).to eq(%w[demo-aaaa-s1 demo-aaaa-s2])
      expect(start.locked).to eq("Tests/OneTests.swift" => oid(base, "Tests/OneTests.swift"),
                                 "Tests/TwoTests.swift" => oid(base, "Tests/TwoTests.swift"))
    end

    it "runs an edited step again, and every step after it" do
      edited = Runeforge::PlanFile.parse(plan_text.sub("Add the model.", "Add the model, edited."))
      expect(progress.start(edited, base:).skip).to eq(1)
    end

    it "keeps a checked-off step's key and its tests' locks" do
      checked = Runeforge::PlanFile.parse(plan_text.sub("### Step 1: Setup", "### [x] Step 1: Setup"))
      expect(checked.checked_steps.map(&:key)).to eq([plan.steps[0].key])
      start = progress.start(checked, base:)
      expect(start.skip).to eq(1) # step 2 is now the first step
      expect(start.locked.keys).to include("Tests/OneTests.swift")
    end

    it "doesn't skip a step whose work is no longer in the base branch" do
      git(origin, "reset", "-q", "--hard", shas.first)
      start = progress.start(plan, base: env.repos.refresh("proj"))
      expect(start.skip).to eq(1)
      expect(start.notes).to include(a_string_including("step 2 (Step 2: Model) was done in task demo-aaaa-s2", "isn't in the base branch"))
    end

    it "starts where --from says, refusing to skip a step that isn't done" do
      expect(progress.start(plan, base:, from: 2).skip).to eq(1)
      expect { progress.start(plan, base:, from: 4) }
        .to raise_error(Runeforge::Error, /step 3 \(Step 3: Engine\) isn't done.*mark-done/)
      expect { progress.start(plan, base:, from: 9) }.to raise_error(Runeforge::Error, /between 1 and 4/)
    end

    it "ignores earlier runs with --rerun, still locking the tests of steps skipped with --from" do
      expect(progress.start(plan, base:, rerun: true).skip).to eq(0)
      start = progress.start(plan, base:, from: 4, rerun: true)
      expect(start).to have_attributes(skip: 3, done: [nil, nil, nil])
      expect(start.locked.keys).to contain_exactly("Tests/OneTests.swift", "Tests/TwoTests.swift")
    end

    it "finds the runs in the repo, their plans and whether they finished" do
      expect(progress.runs.size).to eq(1)
      run = progress.runs.first
      expect(run).to include(id: "demo-aaaa", lane: "fg-aaaa", finished: false, live: false)
      expect(run[:plan].steps.size).to eq(4)
    end

    it "treats a run as live while its unfinished task changed recently" do
      add_task("demo-bbbb-s3", plan.steps[2], status: "coding", base: shas.last, lane: "fg-bbbb", age: 5)
      expect(progress.runs.find { |run| run[:lane] == "fg-bbbb" }[:live]).to be(true)
    end

    describe ".mark_done" do
      it "marks a failed step done at a commit in the base branch, locking the tests it changed" do
        fix = commit(origin, { "Tests/ThreeTests.swift" => "3", "Tests/TwoTests.swift" => "2, fixed" }, "a person finishes step 3")
        task = described_class.mark_done(env, "demo-aaaa-s3", sha: fix[0, 7])

        expect(task).to include(status: "done", merged_sha: fix, head_sha: fix, error: nil)
        expect(JSON.parse(task[:locked_paths])).to include("Tests/ThreeTests.swift" => oid(fix, "Tests/ThreeTests.swift"),
                                                           "Tests/TwoTests.swift" => oid(fix, "Tests/TwoTests.swift"))
        record = env.tasks.messages("demo-aaaa-s3").last
        expect(record.type).to eq("task.marked_done")
        expect(env.db[:runeforge_messages].where(id: record.id).get(:state)).to eq("done")
        expect(described_class.new(env, "proj").start(plan, base: env.repos.refresh("proj")).skip).to eq(3)
      end

      it "refuses an unknown commit, a commit outside the base branch, a done task and a running one" do
        expect { described_class.mark_done(env, "demo-aaaa-s3", sha: "deadbeef") }.to raise_error(Runeforge::Error, /isn't a commit/)
        git(origin, "switch", "-q", "-c", "side")
        side = commit(origin, { "x" => "y" }, "side")
        git(origin, "switch", "-q", "main")
        expect { described_class.mark_done(env, "demo-aaaa-s3", sha: side) }.to raise_error(Runeforge::Error, /isn't in main/)
        expect { described_class.mark_done(env, "demo-aaaa-s1", sha: shas.first) }.to raise_error(Runeforge::Error, /already done/)
        add_task("demo-cccc-s3", plan.steps[2], status: "coding", base: shas.last, lane: "fg-cccc")
        expect { described_class.mark_done(env, "demo-cccc-s3", sha: shas.last) }.to raise_error(Runeforge::Error, /still coding/)
      end
    end
  end

  context "with manual merging, where the steps stack on one branch" do
    let(:manual_merge) { true }

    it "continues on the last done step's branch, from its head" do
      clone = env.repos.path("proj")
      git(clone, "update-ref", "refs/heads/runeforge/demo", base0)
      work = File.join(tmpdir, "work")
      git(clone, "worktree", "add", "-q", work, "runeforge/demo")
      m1 = commit(work, { "Tests/OneTests.swift" => "1" }, "s1")
      m2 = commit(work, { "Tests/TwoTests.swift" => "2" }, "s2")
      add_task("demo-eeee-s1", plan.steps[0], status: "done", base: base0, head: m1, branch: "runeforge/demo", locked: { "Tests/OneTests.swift" => "x" })
      add_task("demo-eeee-s2", plan.steps[1], status: "done", base: m1, head: m2, branch: "runeforge/demo",
                                              locked: { "Tests/OneTests.swift" => "x", "Tests/TwoTests.swift" => "y" })

      start = progress.start(plan, base: env.repos.refresh("proj"))
      expect(start).to have_attributes(skip: 2, base: m2, branch: "runeforge/demo")
      expect(start.locked["Tests/TwoTests.swift"]).to eq(oid(m2, "Tests/TwoTests.swift"))
    end
  end
end
