# frozen_string_literal: true

RSpec.describe Runeforge::Daemons do
  let(:backend) { "sqlite" }
  let(:config_path) { File.join(tmpdir, "runeforge.yml") }
  let(:env) do
    File.write(config_path, YAML.dump("database" => "sqlite://#{File.join(tmpdir, 'test.db')}", "home" => File.join(tmpdir, "home"),
                                      "sandbox" => { "mode" => "none" }, "poll_seconds" => 0.2, "workers" => ["tester, reviewer"]))
    Runeforge::Environment.new(Runeforge::Config.load(config_path), db:)
  end
  let(:daemons) { described_class.new(env, config_path:, stop_timeout: 10) }

  after { daemons.down }

  def wait_until(seconds = 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.1 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  it "names one process per configured worker plus the supervisor" do
    expect(daemons.processes).to eq("supervisor" => ["supervisor"], "worker-tester-reviewer" => ["worker", "--role", "tester,reviewer"])
  end

  it "starts processes once, reports them, and stops them cleanly" do
    started = daemons.up
    expect(started.map(&:state)).to all(eq("started"))
    expect(daemons.up.map(&:state)).to all(eq("already running"))

    wait_until { db[:runeforge_workers].count == 1 }
    expect(db[:runeforge_workers].select_map(:roles)).to eq(["tester,reviewer"])
    expect(daemons.status.map(&:state)).to all(eq("running"))

    stopped = daemons.down
    expect(stopped.map(&:state)).to all(eq("stopped"))
    expect(started.map(&:pid)).to all(satisfy { |pid| !system("kill -0 #{pid} 2>/dev/null") })
    wait_until { db[:runeforge_workers].count.zero? }
    expect(db[:runeforge_workers].count).to eq(0)
  end

  it "manages daemons started from a different install of runeforge" do
    started = daemons.up
    stub_const("Runeforge::Daemons::EXE", "/somewhere/else/gems/runeforge-9.9.9/exe/runeforge")

    expect(daemons.status.map(&:state)).to all(eq("running"))
    expect(daemons.down.map(&:state)).to all(eq("stopped"))
    expect(started.map(&:pid)).to all(satisfy { |pid| !system("kill -0 #{pid} 2>/dev/null") })
  end

  it "ignores a stale pid file" do
    run_dir = File.join(env.home, "run")
    FileUtils.mkdir_p(run_dir)
    File.write(File.join(run_dir, "supervisor.pid"), Process.pid.to_s) # a live process, but not runeforge
    expect(daemons.running_pid("supervisor")).to be_nil
    expect(File.exist?(File.join(run_dir, "supervisor.pid"))).to be(false)
  end
end
