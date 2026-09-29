# frozen_string_literal: true

RSpec.describe Runeforge::Supervisor do
  on_each_backend do
    let(:env) { build_env }
    let(:supervisor) { described_class.new(env) }
    let(:box) { env.mailbox("fake-worker") }
    let(:messages) { db[:runeforge_messages] }

    def create_task(workflow: "jira_to_pr", max_attempts: 2)
      env.tasks.create(id: "T-1", workflow:, repo: "demo", base_sha: "a" * 40, mailbox: env.mailbox("intake"),
                       title: "Greet", input: { "title" => "Greet" }, max_attempts:)
    end

    # Answers the next command for `role` with a result.
    def respond(role, type, payload = {}, sha: nil)
      msg = box.claim(role) || raise("no #{role} command waiting")
      box.complete(msg, result_type: type, payload:, commit_sha: sha)
      msg
    end

    def task = env.tasks.find!("T-1")

    it "walks the happy path to a finished task" do
      create_task
      supervisor.tick
      expect(task[:status]).to eq("planning")

      respond("planner", "plan.done", { "spec" => "Say hi", "locked_paths" => { "test/a_test.sh" => "abc" } }, sha: "b" * 40)
      supervisor.tick
      expect(task).to include(status: "coding", attempts: 1, head_sha: "b" * 40, spec: "Say hi")
      expect(JSON.parse(task[:locked_paths])).to eq("test/a_test.sh" => "abc")

      respond("coder", "code.done", sha: "c" * 40)
      supervisor.tick
      respond("tester", "test.result", { "passed" => true }, sha: "c" * 40)
      supervisor.tick
      respond("reviewer", "review.verdict", { "approved" => true }, sha: "c" * 40)
      supervisor.tick
      expect(task[:status]).to eq("integrating")

      respond("integrator", "integrate.done", { "pr_url" => "https://example.test/pr/1" })
      supervisor.tick
      expect(task).to include(status: "done", external_pr_url: "https://example.test/pr/1")
    end

    it "retries with feedback, then fails at the attempt limit" do
      create_task(max_attempts: 2)
      supervisor.tick
      respond("planner", "plan.done", { "spec" => "", "locked_paths" => {} }, sha: "b" * 40)
      supervisor.tick
      respond("coder", "code.done", sha: "c" * 40)
      supervisor.tick
      respond("tester", "test.result", { "passed" => false, "output_tail" => "FAIL test/a_test.sh" }, sha: "c" * 40)
      supervisor.tick

      retry_msg = box.claim("coder")
      expect(retry_msg.payload).to include("attempt" => 2)
      expect(retry_msg.payload["feedback"]).to include("FAIL test/a_test.sh")

      box.complete(retry_msg, result_type: "code.failed", payload: { "reason" => "nope" })
      supervisor.tick
      expect(task[:status]).to eq("failed")
      expect(task[:error]).to include("attempt limit reached (2/2)", "nope")
      expect(messages.where(task_id: "T-1", state: "pending").count).to eq(0)
    end

    it "fails instead of sending more agent work once the token budget is spent" do
      create_task
      env.tasks.update("T-1", token_budget: 100, tokens_used: 150)
      supervisor.tick
      expect(task[:status]).to eq("failed")
      expect(task[:error]).to include("token budget exhausted")
    end

    it "discards results that arrive after a task is cancelled" do
      create_task
      supervisor.tick
      msg = box.claim("planner")
      env.tasks.cancel("T-1")

      expect { box.complete(msg, result_type: "plan.done") }.to raise_error(Runeforge::Mailbox::LeaseLost)
      supervisor.tick
      expect(task[:status]).to eq("cancelled")
    end

    it "dead-letters a message whose handler keeps raising and blocks the task" do
      Runeforge.workflow(:exploding) { on("task.created") { raise "handler bug" } }
      create_task(workflow: "exploding")
      supervisor.tick

      created = messages.where(type: "task.created").first
      expect(created).to include(state: "dead", delivery_count: 3)
      expect(created[:last_error]).to include("handler bug")
      expect(task[:status]).to eq("blocked")
    ensure
      Runeforge.workflows.delete("exploding")
    end
  end
end
