# frozen_string_literal: true

RSpec.describe Runeforge::Worker do
  on_each_backend do
    let(:messages) { db[:runeforge_messages] }

    def start_task(env)
      add_repo(env)
      Runeforge::Intake.new(env).create(repo: "demo", id: "T-1", title: "Greet", description: "Say hello")
      Runeforge::Supervisor.new(env).tick
    end

    def elapsed(started) = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    it "kills the sandbox and discards the result when its task is cancelled mid-run" do
      env = build_env("agent" => { "command" => "sh #{fake_agent(plan: 'sleep 30', code: 'true')}" }, "heartbeat_seconds" => 0.1)
      start_task(env)
      worker = described_class.new(env, roles: ["planner"])

      canceller = Thread.new { sleep 1; env.tasks.cancel("T-1") }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(worker.work_once).to be(true)
      canceller.join

      expect(elapsed(started)).to be < 10
      expect(messages.where(type: %w[plan.done plan.failed]).count).to eq(0)
      expect(env.tasks.find!("T-1")[:status]).to eq("cancelled")
    end

    it "gives the message back when the role handler crashes" do
      env = build_env
      start_task(env)
      allow(Runeforge::Roles::Planner).to receive(:call).and_raise(RuntimeError, "boom")

      described_class.new(env, roles: ["planner"]).work_once
      expect(messages.where(type: "plan.request").first).to include(state: "pending", last_error: "RuntimeError: boom")
    end

    it "registers while running and removes itself on exit" do
      env = build_env
      worker = described_class.new(env, roles: %w[tester reviewer])
      seen = nil
      worker.run(stop: -> { seen = db[:runeforge_workers].select_map(:roles); true })

      expect(seen).to eq(["tester,reviewer"])
      expect(db[:runeforge_workers].count).to eq(0)
    end

    it "announces itself before its first claim when driven one job at a time, as a foreground build does" do
      env = build_env
      start_task(env)
      worker = described_class.new(env, roles: ["planner"])
      worker.work_once
      worker.work_once

      events = env.db[:runeforge_events].order(:id).all
      started = events.select { |e| e[:kind] == "worker.started" && e[:actor] == worker.id }
      claimed = events.find { |e| e[:kind] == "message.claimed" && e[:actor] == worker.id }
      expect(started.size).to eq(1)
      expect(started.first[:id]).to be < claimed[:id]

      worker.unregister
      expect(env.db[:runeforge_events].where(kind: "worker.stopped", actor: worker.id).count).to eq(1)
    end

    it "refuses unknown roles" do
      expect { described_class.new(build_env, roles: ["wizard"]) }.to raise_error(Runeforge::Error, /unknown roles: wizard/)
    end
  end
end
