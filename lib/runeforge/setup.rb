# frozen_string_literal: true

require "uri"

module Runeforge
  # First-run setup behind `runeforge init`. Every step is safe to repeat: it checks what is
  # already in place and only does what is missing.
  class Setup
    class StepFailed < Error; end

    Step = Data.define(:name, :status, :detail) # status: ok, skipped, warning, failed

    DEFAULT_IMAGE = "runeforge/general:latest"
    DOCKERFILE = File.expand_path("../../docker/Dockerfile.general", __dir__)

    # System interaction, separated so specs can stand in for Docker, brew and friends.
    class Shell
      def run?(*cmd) = system(*cmd, out: File::NULL, err: File::NULL)

      def run!(*cmd) = system(*cmd) || raise(StepFailed, "`#{cmd.join(' ')}` failed")

      def which(name)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }
           .find { |path| File.executable?(path) && !File.directory?(path) }
      end

      def capture(*cmd)
        out, status = Open3.capture2(*cmd, err: File::NULL)
        status.success? ? out : ""
      end

      def macos? = RUBY_PLATFORM.include?("darwin")

      def pause(seconds) = sleep(seconds)
    end

    attr_reader :steps

    # options: database, home, sandbox, adapter, repo, repo_url, test_command, setup_command,
    # base_branch, image, skip_image, start, wait_seconds
    def initialize(config_path:, options: {}, shell: Shell.new, out: $stdout)
      @config_path = File.expand_path(config_path)
      @options = options.transform_keys(&:to_sym)
      @shell = shell
      @out = out
      @steps = []
    end

    def run
      step("config") { write_config }
      config = Config.load(@config_path)
      step("git") { @shell.which("git") ? ok("found #{@shell.which('git')}") : fail!("git is not installed") }
      step("database") { ensure_database(config["database"]) }
      @env = Environment.new(config)
      step("migrations") { migrate }
      step("container runtime") { ensure_runtime }
      step("agent image") { ensure_image }
      step("repository") { ensure_repo }
      step("secrets") { check_secrets }
      if @options.fetch(:start, true)
        step("daemons") { start_daemons }
        step("health") { check_health }
      end
      @out.puts(summary)
      self
    end

    def env = @env

    # What a foreground build needs before it starts: tables, a running container runtime and the
    # image. Only prints steps that did something or need attention.
    def prepare(env)
      @env = env
      @quiet = true
      step("migrations") { migrate }
      step("container runtime") { ensure_runtime }
      step("agent image") { ensure_image }
      self
    end

    private

    def step(name)
      result = yield
      @steps << Step.new(name:, status: result[0], detail: result[1])
      quiet = @quiet && (result[0] == :skipped || (result[0] == :ok && result[1].match?(/already up to date|is running|is present/)))
      @out.puts(format("%s %-18s %s", ICONS.fetch(result[0]), name, result[1])) unless quiet
    rescue StepFailed, Error, Sequel::Error => e
      @steps << Step.new(name:, status: :failed, detail: e.message)
      @out.puts(format("%s %-18s %s", ICONS.fetch(:failed), name, e.message))
      raise StepFailed, "setup stopped at #{name}: #{e.message}"
    end

    ICONS = { ok: "✓", skipped: "-", warning: "!", failed: "✗" }.freeze

    def ok(detail) = [:ok, detail]

    def skipped(detail) = [:skipped, detail]

    def warning(detail) = [:warning, detail]

    def fail!(detail) = raise(StepFailed, detail)

    # --- config ------------------------------------------------------------------------------

    def write_config
      return ok("using existing #{relative(@config_path)}") if File.exist?(@config_path)

      settings = {
        "database" => @options[:database],
        "home" => @options[:home],
        "sandbox" => { "mode" => @options[:sandbox], "image" => @options[:image] }.compact,
        "agent" => { "model" => @options[:model], "adapter" => @options[:adapter] }.compact,
        "workers" => Config::DEFAULTS["workers"]
      }.compact.reject { |_key, value| value.respond_to?(:empty?) && value.empty? }
      FileUtils.mkdir_p(File.dirname(@config_path))
      File.write(@config_path, <<~YAML + YAML.dump(settings).delete_prefix("---\n"))
        # Written by `runeforge init`. Every option is documented in runeforge.yml.example.
        # Secrets are read from environment variables, never from this file.
      YAML
      ok("wrote #{relative(@config_path)}")
    end

    # --- database ----------------------------------------------------------------------------

    def ensure_database(url)
      return ensure_sqlite(url) if url.start_with?("sqlite")
      return fail!("unsupported database URL #{url}") unless url.start_with?("postgres")

      probe(url)
      ok("connected to #{redact(url)}")
    rescue Sequel::DatabaseConnectionError => e
      if e.message.include?("does not exist")
        create_postgres_database(url)
      elsif e.message.match?(/connection refused|No such file or directory|could not connect/i)
        start_postgres(url)
      else
        raise
      end
    end

    def ensure_sqlite(url)
      path = url.sub(%r{\Asqlite:/+}) { |prefix| prefix == "sqlite:///" ? "/" : "" }
      FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
      ok("SQLite at #{File.expand_path(path)}")
    end

    def probe(url)
      Sequel.connect(url, max_connections: 1, &:test_connection)
    end

    def create_postgres_database(url)
      uri = URI(url)
      name = uri.path.delete_prefix("/")
      admin = uri.dup.tap { |u| u.path = "/postgres" }.to_s
      Sequel.connect(admin, max_connections: 1) { |db| db.run("CREATE DATABASE #{db.quote_identifier(name)}") }
      ok("created database #{name}")
    end

    def start_postgres(url)
      formula = @shell.macos? && @shell.which("brew") &&
                @shell.capture("brew", "list", "--formula").lines.map(&:strip).grep(/\Apostgresql(@\d+)?\z/).max
      fail!("PostgreSQL is not running at #{redact(url)}; start it and run `runeforge init` again") unless formula

      @shell.run!("brew", "services", "start", formula)
      wait_for("PostgreSQL") { probe_ok?(url) || database_missing?(url) }
      return ok("started #{formula}") unless database_missing?(url)

      _status, created = create_postgres_database(url)
      ok("started #{formula}; #{created}")
    end

    def probe_ok?(url)
      probe(url)
      true
    rescue Sequel::DatabaseConnectionError
      false
    end

    def database_missing?(url)
      probe(url)
      false
    rescue Sequel::DatabaseConnectionError => e
      e.message.include?("does not exist")
    end

    def migrate
      before = DB.migrated?(@env.db)
      DB.migrate!(@env.db)
      ok(before ? "schema already up to date" : "created Runeforge tables")
    end

    # --- containers --------------------------------------------------------------------------

    def runtime = @env.config.dig("sandbox", "mode")

    def ensure_runtime
      return warning("sandbox.mode is none: agents run directly on this machine, without isolation") if runtime == "none"
      fail!("#{runtime} is not installed; install it or set sandbox.mode") unless @shell.which(runtime)
      return ok("#{runtime} is running") if runtime_up?

      @out.puts("  starting #{runtime}...")
      start_runtime
      wait_for(runtime) { runtime_up? }
      ok("started #{runtime}")
    end

    def runtime_up? = @shell.run?(runtime, "info")

    def start_runtime
      if runtime == "docker" && @shell.macos?
        @shell.run!("open", "-a", "Docker")
      elsif runtime == "podman" && @shell.macos?
        @shell.run?("podman", "machine", "init") # fails harmlessly if a machine exists
        @shell.run!("podman", "machine", "start")
      elsif runtime == "docker" && @shell.which("systemctl") && @shell.run?("systemctl", "start", "docker")
        nil
      else
        fail!("#{runtime} is installed but not running; start it (e.g. `sudo systemctl start docker`) and run `runeforge init` again")
      end
    end

    def ensure_image
      return skipped("not needed without a sandbox") if runtime == "none"

      image = @env.config.dig("sandbox", "image")
      return ok("#{image} is present") if @shell.run?(runtime, "image", "inspect", image)
      return warning("#{image} is missing; build it with `#{runtime} build -t #{image} -f #{DOCKERFILE} .`") if @options[:skip_image]
      return warning("#{image} is missing; pull or build it before running tasks") unless image == DEFAULT_IMAGE

      @out.puts("  building #{image} from #{relative(DOCKERFILE)} (this takes a few minutes the first time)")
      @shell.run!(runtime, "build", "-t", image, "-f", DOCKERFILE, File.dirname(DOCKERFILE))
      ok("built #{image}")
    end

    # --- repository and secrets --------------------------------------------------------------

    def ensure_repo
      if @options[:repo_url]
        fail!("--test-command is required with --repo-url") unless @options[:test_command]

        name = @options[:repo] || File.basename(@options[:repo_url].to_s, ".git")
        sha = @env.repos.add(name:, url: @options[:repo_url], test_command: @options[:test_command],
                             base_branch: @options[:base_branch] || "main", setup_command: @options[:setup_command])
        return ok("#{name} cloned; #{@options[:base_branch] || 'main'} at #{sha[0, 7]}")
      end

      names = @env.repos.list.map { |repo| repo[:name] }
      names.any? ? ok("registered: #{names.join(', ')}") : warning("none yet; add one with `runeforge repo add NAME --url ... --test-command ...`")
    end

    def check_secrets
      missing = []
      # An API key or a subscription token per role; unsandboxed agents can use the person's own login.
      if runtime != "none"
        %w[planner coder].each do |role|
          agent = @env.agent(role)
          next if agent.adapter.key_env.nil? || @env.agent_key_env(role).any?

          token = agent.adapter.oauth_env && agent.settings["oauth_token_env"]
          options = @env.key_sources(agent).first(2).join(" or ")
          missing << "#{options}#{token ? " or #{token} (from `claude setup-token`)" : ''} (#{role}: #{agent.label})"
        end
      end
      github_env = @env.config.dig("github", "token_env")
      missing << "#{github_env} (opening pull requests)" unless ENV[github_env]
      missing.empty? ? ok("all set") : warning("not set: #{missing.join(', ')}")
    end

    # --- daemons -----------------------------------------------------------------------------

    def daemons = (@daemons ||= Daemons.new(@env, config_path: @config_path))

    def start_daemons
      started = daemons.up
      ok(started.map { |s| "#{s.name} (#{s.state}, pid #{s.pid})" }.join(", "))
    end

    def check_health
      expected = daemons.processes.size - 1
      wait_for("workers to register", seconds: @options.fetch(:wait_seconds, 20)) do
        daemons.status.all? { |s| s.state == "running" } &&
          @env.db[:runeforge_workers].where(Sequel[:heartbeat_at] > Runeforge.now - 60).count >= expected
      end
      ok("supervisor and #{expected} worker#{'s' unless expected == 1} are up; logs in #{File.dirname(daemons.log_path('supervisor'))}")
    rescue StepFailed
      dead = daemons.status.reject { |s| s.state == "running" }
      detail = dead.map { |s| "#{s.name} exited; last log lines:\n#{tail(s.log_path)}" }.join("\n")
      fail!(detail.empty? ? "workers did not register in time" : detail)
    end

    # --- helpers -----------------------------------------------------------------------------

    def wait_for(what, seconds: @options.fetch(:wait_seconds, 120))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      until yield
        fail!("timed out after #{seconds}s waiting for #{what}") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        @shell.pause(1)
      end
    end

    def summary
      warnings = @steps.count { |s| s.status == :warning }
      running = @options.fetch(:start, true) ? "Runeforge is running. Check it with `runeforge ps` and stop it with `runeforge down`." : "Setup done. Start Runeforge with `runeforge up`."
      warnings.zero? ? running : "#{running}\n#{warnings} warning#{'s' unless warnings == 1} above to look at."
    end

    def tail(path, lines = 15) = File.exist?(path) ? File.readlines(path).last(lines).join : "(no log)"

    def relative(path) = path.delete_prefix("#{Dir.pwd}/")

    def redact(url) = url.sub(%r{//([^:/@]+):[^@]+@}, '//\1:***@')
  end
end
