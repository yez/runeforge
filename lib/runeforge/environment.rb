# frozen_string_literal: true

module Runeforge
  # Everything a supervisor, worker or CLI command needs, built from one config.
  class Environment
    attr_reader :config, :db
    attr_writer :github, :jira, :adapter, :sandbox_factory

    def self.load(config_path: Config.locate, database: nil, must_exist: false)
      overrides = database ? { "database" => database } : {}
      new(Config.load(config_path, overrides, must_exist:))
    end

    def initialize(config, db: nil)
      @config = config
      @db = db || DB.connect(config["database"])
      config["workflow_paths"].each { |path| Kernel.load(File.expand_path(path)) }
    end

    def home = config.home

    def tasks = (@tasks ||= Tasks.new(db))

    def repos = (@repos ||= RepoStore.new(db, File.join(home, "repos")))

    def mailbox(worker_id)
      Mailbox.new(db, worker_id:, lease_seconds: config["lease_seconds"], max_deliveries: config["max_deliveries"])
    end

    def sandboxed? = config.dig("sandbox", "mode") != "none"

    def dry_run? = config.dig("dry_run", "enabled") == true

    def adapter = (@adapter ||= Adapters.build(config["agent"], sandboxed: sandboxed?))

    def new_sandbox(image: nil)
      return @sandbox_factory.call(image:) if @sandbox_factory
      return DryRun::Sandbox.new if dry_run?

      Sandbox.build(config["sandbox"], image:)
    end

    def committer(repo_name)
      Committer.new(repos.path(repo_name), limits: config["limits"],
                                           author_name: config.dig("git", "author_name"),
                                           author_email: config.dig("git", "author_email"))
    end

    def github = (@github ||= Integrations::GitHub.from_config(config["github"]))

    def jira = (@jira ||= Integrations::Jira.from_config(config["jira"]))

    # The spend-limited key handed to containers. Local (unsandboxed) runs may fall back to the
    # agent CLI's own variable, since they run as the user anyway.
    def agent_key_env
      value = ENV[config.dig("agent", "key_env")]
      value ||= ENV[adapter.key_env] if !sandboxed? && adapter.key_env
      value && adapter.key_env ? { adapter.key_env => value } : {}
    end

    def logs_dir(task_id) = File.join(home, "logs", task_id.to_s).tap { |dir| FileUtils.mkdir_p(dir) }

    def workspaces_dir = File.join(home, "workspaces")
  end
end
