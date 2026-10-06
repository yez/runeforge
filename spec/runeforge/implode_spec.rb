# frozen_string_literal: true

RSpec.describe Runeforge::Implode do
  # Stands in for docker; `images` is what `docker images` reports.
  class ImplodeShell
    attr_reader :commands

    def initialize(images: [], running: true)
      @images = images
      @running = running
      @commands = []
    end

    def which(name) = name == "docker" ? "/usr/local/bin/docker" : nil

    def run?(*cmd)
      @commands << cmd
      cmd == %w[docker info] ? @running : true
    end

    def run!(*cmd) = run?(*cmd)

    def capture(*_cmd) = @images.map { |image| "#{image}\n" }.join
  end

  let(:home) { File.join(tmpdir, "rf-home") }
  let(:config_path) { File.join(home, "runeforge.yml") }
  let(:out) { StringIO.new }

  # Never let a spec see (or delete) the real ./runeforge.yml, ~/.runeforge/runeforge.yml or ~/.runeforge.
  before do
    stub_const("Runeforge::Config::GLOBAL_PATH", config_path)
    stub_const("Runeforge::Config::LEGACY_PATH", File.join(tmpdir, "cwd-runeforge.yml"))
    stub_const("Runeforge::Config::DEFAULTS", Runeforge::Config::DEFAULTS.merge("home" => File.join(tmpdir, "default-home")).freeze)
  end

  def write_config(extra = {}, marker: true)
    FileUtils.mkdir_p(File.dirname(config_path))
    body = YAML.dump({ "home" => home, "sandbox" => { "mode" => "none" }, "poll_seconds" => 0.2, "workers" => ["tester"] }.merge(extra))
    File.write(config_path, "#{marker ? "#{described_class::INIT_MARKER} Every option...\n" : ''}#{body}")
  end

  def populate_home
    %w[repos/demo logs/daemons workspaces].each { |dir| FileUtils.mkdir_p(File.join(home, dir)) }
    File.write(File.join(home, "logs", "daemons", "supervisor.log"), "log")
    env = Runeforge::Environment.new(Runeforge::Config.load(config_path))
    Runeforge::DB.migrate!(env.db)
    env
  end

  def implode(**opts) = described_class.new(config_path:, shell: ImplodeShell.new(running: false), out:, **opts)

  def pid_alive?(pid) = system("kill -0 #{pid} 2>/dev/null")

  it "stops the daemons and removes the data, home and init-written config" do
    write_config
    env = populate_home
    started = Runeforge::Daemons.new(env, config_path:).up
    env.db.disconnect

    subject = implode
    descriptions = subject.actions.map(&:description)
    expect(descriptions).to include("stop supervisor (pid #{started.first.pid})", "delete #{File.join(home, 'runeforge.db')}",
                                    "delete #{File.join(home, 'repos')}", "delete #{config_path}", "remove #{home}")

    subject.run
    expect(File.exist?(home)).to be(false)
    expect(started.map(&:pid)).to all(satisfy { |pid| !pid_alive?(pid) })
    expect(out.string).not_to include("✗")
  end

  it "keeps a config it didn't write and a home that holds other files" do
    write_config(marker: false)
    populate_home.db.disconnect
    File.write(File.join(home, "notes.txt"), "mine")

    subject = implode
    subject.run
    expect(File.read(File.join(home, "notes.txt"))).to eq("mine")
    expect(File.exist?(config_path)).to be(true)
    expect(Dir.children(home)).to contain_exactly("notes.txt", "runeforge.yml")
    expect(subject.kept).to include("#{config_path} (not written by runeforge init)",
                                    "#{home} (it also holds notes.txt, runeforge.yml, which runeforge didn't create)")
  end

  it "deletes a SQLite database configured outside the home directory" do
    database = File.join(tmpdir, "elsewhere", "rf.db")
    write_config({ "database" => "sqlite://#{database}" })
    populate_home.db.disconnect

    implode.run
    expect(File.exist?(database)).to be(false)
  end

  it "removes the old-default runeforge.db next to an init-written config in another directory" do
    project_config = File.join(tmpdir, "cwd-runeforge.yml")
    File.write(project_config, "#{described_class::INIT_MARKER}\nhome: #{home}\n")
    File.write(File.join(tmpdir, "runeforge.db"), "old")
    write_config

    subject = described_class.new(config_path: project_config, shell: ImplodeShell.new(running: false), out:)
    expect(subject.actions.map(&:description)).to include("delete the SQLite database #{File.join(tmpdir, 'runeforge.db')}")
    subject.run
    expect(File.exist?(File.join(tmpdir, "runeforge.db"))).to be(false)
  end

  it "removes runeforge images unless asked to keep them" do
    write_config
    shell = ImplodeShell.new(images: ["runeforge/general:latest", "runeforge/demo:latest", "runeforge/old:<none>"])
    subject = described_class.new(config_path:, shell:, out:)
    expect(subject.actions.map(&:description)).to include("remove container images runeforge/general:latest, runeforge/demo:latest")
    subject.run
    expect(shell.commands).to include(%w[docker rmi --force runeforge/general:latest runeforge/demo:latest])

    kept = described_class.new(config_path:, shell: ImplodeShell.new(images: ["runeforge/general:latest"]), keep_images: true, out:)
    expect(kept.actions.map(&:description).grep(/image/)).to be_empty
    expect(kept.kept).to include("container images (--keep-images): runeforge/general:latest")
  end

  it "refuses to touch a home setting that points at the user's home directory" do
    write_config({ "home" => Dir.home, "database" => "sqlite://#{File.join(tmpdir, 'rf.db')}" })
    subject = implode
    expect(subject.actions.map(&:description).grep(/#{Regexp.escape(Dir.home)}\/(repos|logs|workspaces|run)/)).to be_empty
    expect(subject.kept.join).to include("isn't a Runeforge-only directory")
  end

  context "with PostgreSQL", if: Backends::PG_URL do
    it "drops only the Runeforge tables and keeps the database" do
      Sequel.connect(Backends::PG_URL) do |db|
        db.drop_table?(*Backends::TABLES)
        Runeforge::DB.migrate!(db)
        db.create_table!(:not_runeforge) { primary_key :id }
      end
      write_config({ "database" => Backends::PG_URL })

      implode.run
      Sequel.connect(Backends::PG_URL) do |db|
        expect(Backends::TABLES.map { |table| db.table_exists?(table) }).to all(be(false))
        expect(db.table_exists?(:not_runeforge)).to be(true)
        db.drop_table(:not_runeforge)
      end
    end
  end

  describe "runeforge implode" do
    def cli(*args, input: "")
      allow(Runeforge::Setup::Shell).to receive(:new).and_return(ImplodeShell.new(running: false))
      original_out = $stdout
      original_in = $stdin
      $stdout = StringIO.new
      $stdin = StringIO.new(input)
      Runeforge::CLI.start(["implode", "-c", config_path, *args])
      $stdout.string
    rescue SystemExit
      $stdout.string
    ensure
      $stdout = original_out
      $stdin = original_in
    end

    before do
      write_config
      populate_home.db.disconnect
    end

    it "lists what it would remove on a dry run and changes nothing" do
      output = cli("--dry-run")
      expect(output).to include("This will:", "delete #{File.join(home, 'repos')}", "Not touched: your project directories", "Dry run")
      expect(File.exist?(File.join(home, "repos"))).to be(true)
    end

    it "does nothing unless the confirmation is typed exactly" do
      expect { cli(input: "yes\n") }.to output(/Cancelled; nothing was removed/).to_stderr
      expect(File.exist?(config_path)).to be(true)
    end

    it "wipes everything after confirmation" do
      output = cli(input: "implode\n")
      expect(output).to include("✓ delete #{config_path}", "Runeforge's local setup is gone")
      expect(File.exist?(home)).to be(false)
    end

    it "skips the question with --yes, and refuses a -c path that doesn't exist" do
      expect(cli("--yes")).to include("Runeforge's local setup is gone")
      expect { cli("--yes") }.to output(/config file not found: #{Regexp.escape(config_path)}/).to_stderr
    end
  end
end
