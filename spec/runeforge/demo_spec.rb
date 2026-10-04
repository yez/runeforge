# frozen_string_literal: true

RSpec.describe Runeforge::Demo do
  let(:backend) { "sqlite" }
  let(:env) { build_env("dry_run" => { "enabled" => true, "min_seconds" => 0, "max_seconds" => 0.01, "failure_rate" => 0 }) }

  it "keeps tasks flowing and trims old ones" do
    demo = described_class.new(env, concurrency: 2, keep_finished: 1, out: StringIO.new)
    2.times { demo.top_up }
    demo.top_up
    expect(env.tasks.list.map { |t| t[:id] }).to contain_exactly("DEMO-1", "DEMO-2")

    %w[DEMO-1 DEMO-2].each { |id| drive(env, id, until_status: "done") }
    demo.top_up
    expect(env.tasks.find("DEMO-3")).to include(status: "pending", title: described_class::TITLES[2])

    demo.trim
    expect(env.tasks.list.map { |t| t[:id] }).to contain_exactly("DEMO-2", "DEMO-3")
    expect(db[:runeforge_messages].where(task_id: "DEMO-1").count).to eq(0)
  end

  it "runs the supervisor and workers until stopped" do
    demo = described_class.new(env, concurrency: 1, out: StringIO.new).start
    deadline = Time.now + 20
    sleep 0.1 until env.tasks.find("DEMO-1")&.dig(:status) == "done" || Time.now > deadline
    demo.stop(timeout: 5)

    expect(env.tasks.find("DEMO-1")[:status]).to eq("done")
    expect(db[:runeforge_workers].count).to eq(0)
  end
end
