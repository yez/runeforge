# frozen_string_literal: true

module Runeforge
  # `runeforge implode`: removes what `runeforge init` and normal use created on this machine.
  # Only known Runeforge paths are deleted, so a mistyped home setting can't take other files
  # with it. Project directories and their runeforge/* branches are left alone.
  class Implode
    Action = Data.define(:description, :run)

    INIT_MARKER = "# Written by `runeforge init`."
    HOME_ENTRIES = %w[repos logs workspaces run runeforge.db runeforge.db-wal runeforge.db-shm].freeze
    TABLES = %i[runeforge_workers runeforge_messages runeforge_tasks runeforge_repos runeforge_schema_info].freeze

    attr_reader :kept

    # must_exist: the path was given explicitly, so a missing file is an error rather than
    # "use the defaults" (which would point implode at the default home instead).
    def initialize(config_path:, database: nil, keep_images: false, must_exist: false, shell: Setup::Shell.new, out: $stdout)
      @config_path = config_path
      @config = Config.load(config_path, database ? { "database" => database } : {}, must_exist:)
      @keep_images = keep_images
      @shell = shell
      @out = out
      @kept = []
    end

    def home = @config.home

    # Everything implode would do, in order. Building the list changes nothing.
    def actions
      [daemon_actions, database_actions, image_actions, home_actions, config_actions, remove_home_action].flatten.compact
    end

    def run(actions = self.actions)
      actions.each do |action|
        action.run.call
        @out.puts "✓ #{action.description}"
      rescue StandardError => e
        @out.puts "✗ #{action.description}: #{e.message}"
      end
    end

    private

    def daemon_actions
      return [] unless File.directory?(File.join(home, "run")) # checking would otherwise create it

      daemons = Daemons.new(Struct.new(:config, :home).new(@config, home), config_path: @config_path, stop_timeout: 15)
      running = daemons.status.select { |status| status.state == "running" }
      running.map do |status|
        Action.new(description: "stop #{status.name} (pid #{status.pid})", run: -> { daemons.stop(status.name) })
      end
    end

    def database_actions
      url = @config["database"]
      if url.start_with?("sqlite")
        path = url.sub(%r{\Asqlite:/+}) { |prefix| prefix == "sqlite:///" ? "/" : "" }
        path = File.expand_path(path)
        # Files inside home go with the home entries below.
        return [] if path.start_with?("#{home}/") && HOME_ENTRIES.include?(File.basename(path))

        files = [path, "#{path}-wal", "#{path}-shm"].select { |file| File.exist?(file) }
        return [] if files.empty?

        [Action.new(description: "delete the SQLite database #{path}", run: -> { FileUtils.rm_f(files) })]
      else
        postgres_actions(url)
      end
    end

    def postgres_actions(url)
      present = Sequel.connect(url, max_connections: 1) { |db| TABLES.select { |table| db.table_exists?(table) } }
      return [] if present.empty?

      label = url.sub(%r{//([^:/@]+):[^@]+@}, '//\1:***@')
      [Action.new(description: "drop #{present.size} Runeforge tables from #{label} (the database itself is kept)",
                  run: -> { Sequel.connect(url, max_connections: 1) { |db| db.drop_table?(*present) } })]
    rescue Sequel::DatabaseConnectionError => e
      @kept << "Runeforge tables in #{url}: couldn't connect (#{e.message.lines.first&.strip})"
      []
    end

    def image_actions
      runtime = %w[docker podman].find { |name| @shell.which(name) && @shell.run?(name, "info") }
      if runtime.nil?
        @kept << "runeforge/* container images: no running Docker or Podman to remove them with"
        return []
      end

      images = @shell.capture(runtime, "images", "--filter", "reference=runeforge/*", "--format", "{{.Repository}}:{{.Tag}}")
                     .lines.map(&:strip).reject { |image| image.empty? || image.end_with?(":<none>") }.uniq
      return [] if images.empty?

      if @keep_images
        @kept << "container images (--keep-images): #{images.join(', ')}"
        return []
      end

      [Action.new(description: "remove container images #{images.join(', ')}",
                  run: -> { @shell.run!(runtime, "rmi", "--force", *images) })]
    end

    def home_actions
      return [] unless File.directory?(home)
      if unsafe_home?
        @kept << "#{home}: home is set to #{home}, which isn't a Runeforge-only directory, so nothing in it was touched"
        return []
      end

      HOME_ENTRIES.map { |name| File.join(home, name) }.select { |path| File.exist?(path) }.map do |path|
        Action.new(description: "delete #{path}", run: -> { FileUtils.rm_rf(path) })
      end
    end

    # Runs last, after the config inside it is gone; only removes home if nothing else is in it.
    def remove_home_action
      return nil if !File.directory?(home) || unsafe_home?

      global_in_home = File.dirname(Config::GLOBAL_PATH) == home && init_config?(Config::GLOBAL_PATH)
      others = Dir.children(home) - HOME_ENTRIES - (global_in_home ? [File.basename(Config::GLOBAL_PATH)] : [])
      unless others.empty?
        @kept << "#{home} (it also holds #{others.sort.join(', ')}, which runeforge didn't create)"
        return nil
      end

      Action.new(description: "remove #{home}", run: -> { Dir.rmdir(home) if Dir.exist?(home) && Dir.empty?(home) })
    end

    # "/" or the user's home directory (or anything above it) holds more than Runeforge's files.
    def unsafe_home?
      user_home = File.expand_path(Dir.home)
      home == "/" || home == user_home || user_home.start_with?("#{home}/")
    end

    def config_actions
      candidates = [@config_path, File.expand_path(Config::DEFAULT_PATH), Config::GLOBAL_PATH].map { |path| File.expand_path(path) }.uniq
      candidates.select { |path| File.exist?(path) }.flat_map do |path|
        if init_config?(path)
          [Action.new(description: "delete #{path}", run: -> { FileUtils.rm_f(path) }), *legacy_database_action(path)]
        else
          @kept << "#{path} (not written by runeforge init)"
          []
        end
      end
    end

    # Before 0.1.0's config move, a config without a database line used runeforge.db in the
    # directory runeforge was run from, which is where init wrote the config.
    def legacy_database_action(config_file)
      return [] if (YAML.safe_load_file(config_file) || {}).key?("database")

      database = File.join(File.dirname(config_file), "runeforge.db")
      files = [database, "#{database}-wal", "#{database}-shm"].select { |file| File.exist?(file) }
      return [] if files.empty? || File.dirname(database) == home

      [Action.new(description: "delete the SQLite database #{database}", run: -> { FileUtils.rm_f(files) })]
    end

    def init_config?(path) = File.exist?(path) && File.open(path, &:gets).to_s.start_with?(INIT_MARKER)
  end
end
