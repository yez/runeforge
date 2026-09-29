# frozen_string_literal: true

RSpec.describe Runeforge::CLI do
  let(:backend) { "sqlite" }
  let(:env) { build_env("agent" => { "command" => "sh #{fake_agent(plan: Helpers::PLAN_GREETING, code: Helpers::CODE_GREETING)}" }) }

  def cli(*args)
    out = StringIO.new
    original = $stdout
    $stdout = out
    described_class.start([*args, "--database", "sqlite://#{File.join(tmpdir, 'test.db')}"])
    out.string
  ensure
    $stdout = original
  end

  before do
    add_repo(env)
    Runeforge::Intake.new(env).create(repo: "demo", id: "T-1", title: "Greet", description: "Say hello")
    drive(env, "T-1", until_status: "done")
  end

  it "shows a task's status and message history" do
    output = cli("status", "T-1")
    expect(output).to include("T-1  jira_to_pr  status: done   attempt 1/5", "branch runeforge/T-1")
    expect(output).to match(/supervisor\s+→ planner\s+plan\.request/)
    expect(output).to match(/tester\s+→ supervisor\s+test\.result/)
    expect(output).to match(/test\.result\s+\h{7}\s+done\s+passed/)
    expect(output).to match(/integrator\s+→ supervisor\s+integrate\.done/)
  end

  it "lists tasks, filtered by status" do
    expect(cli("tasks", "--status", "done")).to include("T-1", "done", "Greet")
    expect(cli("tasks", "--status", "failed")).not_to include("T-1")
  end

  it "lists and prints logs" do
    expect(cli("logs", "T-1")).to include("test.result", "-tester.log")
    tester = env.tasks.messages("T-1").find { |msg| msg.type == "test.result" }
    expect { cli("logs", "T-1", "--message", tester.id.to_s) }.not_to raise_error
  end

  it "prints its version" do
    expect(cli("version")).to eq("runeforge #{Runeforge::VERSION}\n")
  end
end
