# frozen_string_literal: true

RSpec.describe Runeforge::DryRun do
  on_each_backend do
    def dry_env(failure_rate: 0)
      build_env("dry_run" => { "enabled" => true, "min_seconds" => 0, "max_seconds" => 0.01, "failure_rate" => failure_rate },
                # A real agent run would fail loudly; dry run must never reach it.
                "agent" => { "command" => "exit 99" })
    end

    def create_task(env, id = "D-1")
      # No repo is registered and the base commit doesn't exist: dry run touches neither.
      env.tasks.create(id:, workflow: "jira_to_pr", repo: "nowhere", base_sha: "f" * 40, title: "Dry", mailbox: env.mailbox("t"))
    end

    it "takes a task through every role to done without an LLM, git or a sandbox" do
      env = dry_env
      create_task(env)
      task = drive(env, "D-1", until_status: %w[done failed blocked])

      expect(task).to include(status: "done", attempts: 1)
      expect(task[:external_pr_url]).to start_with("dry-run://pull/")
      expect(task[:tokens_used]).to be > 0
      types = db[:runeforge_messages].where(task_id: "D-1").order(:id).select_map(:type)
      expect(types).to eq(%w[task.created plan.request plan.done code.request code.done test.request test.result
                             review.request review.verdict integrate.request integrate.done])
      roles = Runeforge::Events.since(db, limit: 1_000).select { |e| e[:kind] == "agent.output" }.map { |e| e[:data]["role"] }
      expect(roles.uniq).to match_array(%w[planner coder tester reviewer integrator])
    end

    it "retries and eventually fails when the agents keep failing" do
      env = dry_env(failure_rate: 1)
      env.tasks.create(id: "D-2", workflow: "jira_to_pr", repo: "nowhere", base_sha: "f" * 40, mailbox: env.mailbox("t"))
      task = drive(env, "D-2", until_status: %w[done failed blocked])

      expect(task[:status]).to eq("failed")
      # Planning fails a fifth as often as other steps; otherwise the coder runs out of attempts.
      expect(task[:error]).to match(/planning failed: simulated|attempt limit reached \(5\/5\)/)
    end

    it "stops between steps when the sandbox is killed" do
      env = build_env("dry_run" => { "enabled" => true, "min_seconds" => 5, "max_seconds" => 5, "failure_rate" => 0 })
      create_task(env)
      Runeforge::Supervisor.new(env).tick
      msg = env.mailbox("w").claim("planner")
      sandbox = described_class::Sandbox.new
      Thread.new { sleep 0.2; sandbox.kill }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { described_class::Planner.call(env, msg, sandbox) }.to raise_error(Runeforge::Mailbox::LeaseLost)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
    end

    it "is used by workers only when enabled" do
      expect(dry_env.new_sandbox).to be_a(described_class::Sandbox)
      expect(build_env.new_sandbox).to be_a(Runeforge::Sandbox::Local)
    end
  end
end
