# frozen_string_literal: true

RSpec.describe Runeforge::Setup do
  # Records commands and answers them from a block, standing in for docker, brew and systemctl.
  class FakeShell
    attr_reader :commands

    def initialize(which: { "git" => "/usr/bin/git", "docker" => "/usr/local/bin/docker" }, macos: true, &answer)
      @which = which
      @macos = macos
      @answer = answer || ->(_cmd) { true }
      @commands = []
    end

    def run?(*cmd)
      @commands << cmd
      @answer.call(cmd)
    end

    def run!(*cmd) = run?(*cmd) || raise(Runeforge::Setup::StepFailed, "`#{cmd.join(' ')}` failed")

    def which(name) = @which[name]

    def capture(*) = ""

    def macos? = @macos

    def pause(_seconds) = nil
  end

  let(:config_path) { File.join(tmpdir, "runeforge.yml") }
  let(:out) { StringIO.new }
  let(:base_options) { { database: "sqlite://#{File.join(tmpdir, 'rf.db')}", home: File.join(tmpdir, "home"), wait_seconds: 20 } }

  def setup(shell: FakeShell.new, **options) = described_class.new(config_path:, options: base_options.merge(options), shell:, out:)

  def statuses(result) = result.steps.to_h { |step| [step.name, step.status] }

  # Stop anything a test started. Some tests point at databases that are unreachable or dropped.
  after do
    next unless File.exist?(config_path)

    env = Runeforge::Environment.new(Runeforge::Config.load(config_path))
    Runeforge::Daemons.new(env, config_path:).down
    env.db.disconnect
  rescue Sequel::DatabaseConnectionError
    nil
  end

  it "takes a fresh machine to running daemons, and is safe to run again" do
    first = setup(sandbox: "none").run

    expect(statuses(first)).to include("config" => :ok, "database" => :ok, "migrations" => :ok,
                                       "container runtime" => :warning, "agent image" => :skipped,
                                       "daemons" => :ok, "health" => :ok)
    expect(YAML.safe_load_file(config_path)).to include("sandbox" => { "mode" => "none" }, "workers" => ["planner,coder", "tester,reviewer,integrator"])
    expect(first.env.db[:runeforge_workers].select_map(:roles)).to contain_exactly("planner,coder", "tester,reviewer,integrator")
    expect(Runeforge::Daemons.new(first.env, config_path:).status.map(&:state)).to all(eq("running"))
    expect(out.string).to include("✓ health", "Runeforge is running")

    again = setup.run
    details = again.steps.to_h { |step| [step.name, step.detail] }
    expect(details["config"]).to start_with("using existing")
    expect(details["migrations"]).to eq("schema already up to date")
    expect(details["daemons"]).to include("supervisor (already running")
  end

  it "registers a repository when given one" do
    result = setup(sandbox: "none", start: false, repo_url: make_origin, repo: "demo", test_command: "sh test/run.sh").run
    expect(result.steps.find { |step| step.name == "repository" }.detail).to match(/demo cloned; main at \h{7}/)
    expect(result.env.repos.fetch("demo")[:test_command]).to eq("sh test/run.sh")
  end

  it "starts Docker Desktop and builds the agent image when they are missing" do
    started = false
    shell = FakeShell.new do |cmd|
      case cmd
      in ["docker", "info"] then started
      in ["open", "-a", "Docker"] then started = true
      in ["docker", "image", "inspect", *] then false
      else true
      end
    end
    result = setup(start: false, shell:).run

    expect(statuses(result)).to include("container runtime" => :ok, "agent image" => :ok)
    expect(shell.commands).to include(["open", "-a", "Docker"])
    expect(shell.commands).to include(["docker", "build", "-t", "runeforge/general:latest", "-f", described_class::DOCKERFILE, File.dirname(described_class::DOCKERFILE)])
  end

  it "stops with a clear message when the container runtime is missing" do
    shell = FakeShell.new(which: { "git" => "/usr/bin/git" })
    expect { setup(start: false, shell:).run }.to raise_error(described_class::StepFailed, /docker is not installed/)
    expect(out.string).to include("✗ container runtime")
  end

  it "explains how to start Docker on Linux when it can't start it itself" do
    shell = FakeShell.new(macos: false) { |cmd| cmd != %w[docker info] }
    expect { setup(start: false, shell:).run }.to raise_error(described_class::StepFailed, /sudo systemctl start docker/)
  end

  it "warns instead of building when the image is custom or building is skipped" do
    shell = FakeShell.new { |cmd| cmd[0..1] != %w[docker image] }
    result = setup(start: false, skip_image: true, shell:).run
    expect(result.steps.find { |step| step.name == "agent image" }).to have_attributes(status: :warning)
    expect(shell.commands.map { |cmd| cmd.first(2) }).not_to include(%w[docker build])
  end

  it "explains how to start PostgreSQL when it is down and Homebrew can't help" do
    shell = FakeShell.new(macos: false)
    expect { setup(database: "postgres://localhost:1/runeforge_x", start: false, shell:).run }
      .to raise_error(described_class::StepFailed, /PostgreSQL is not running/)
  end

  context "with PostgreSQL", if: Backends::PG_URL do
    let(:name) { "runeforge_setup_#{SecureRandom.hex(4)}" }
    let(:url) { URI(Backends::PG_URL).tap { |uri| uri.path = "/#{name}" }.to_s }

    after do
      Sequel.connect(URI(Backends::PG_URL).tap { |uri| uri.path = "/postgres" }.to_s) do |admin|
        admin.run("DROP DATABASE IF EXISTS #{admin.quote_identifier(name)} WITH (FORCE)")
      end
    end

    it "creates the database when it doesn't exist" do
      result = setup(database: url, sandbox: "none", start: false).run
      expect(result.steps.find { |step| step.name == "database" }.detail).to eq("created database #{name}")
      expect(result.env.db.table_exists?(:runeforge_messages)).to be(true)
      result.env.db.disconnect
    end
  end
end
