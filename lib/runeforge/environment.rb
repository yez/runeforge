# frozen_string_literal: true

module Runeforge
  # Everything a supervisor, worker or CLI command needs, built from one config.
  class Environment
    attr_reader :config, :db
    attr_writer :github, :jira, :sandbox_factory

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

    # A project is a repo row (or { name:, url: }) for per-project settings; nil means the
    # top-level ones.
    def sandbox_mode(project = nil) = config.sandbox_mode_for(project)

    def sandboxed?(project = nil) = sandbox_mode(project) != "none"

    # Whether a repo's finished work is left for a person to merge, and how GitHub merges it:
    # its entry under `projects` in runeforge.yml, else the top-level setting.
    def manual_merge?(repo_name) = config.for_project(repo_row(repo_name), "manual_merge") == true

    def merge_method(repo_name) = config.for_project(repo_row(repo_name), "merge_method")

    def repo_row(name) = name && repos.table.where(name: name.to_s).first

    def dry_run? = config.dig("dry_run", "enabled") == true

    # The agent CLI for the default model (see #agent for a role's).
    def adapter = agent.adapter

    # One role's agent: `agent:` settings, overridden by `agent.roles.<role>`. A role that picks a
    # different model or provider doesn't inherit the default CLI or API key variable.
    def agent(role = nil, project: nil)
      (@agents ||= {})["#{role}|#{sandbox_mode(project)}"] ||= begin
        base = config["agent"]
        own = role ? (base["roles"] || {}).fetch(role.to_s, {}) : {}
        settings = base.except("roles").merge(own)
        if own.key?("model") || own.key?("provider")
          settings["adapter"] = own["adapter"]
          settings["key_env"] = own["key_env"]
        end
        provider_name, model = Providers.split(settings["model"], provider: settings["provider"], adapter: settings["adapter"])
        provider = Providers.fetch(provider_name, key_var: settings["container_key_env"])
        adapter_name = settings["adapter"] || default_adapter(provider, settings, project:)
        # Vendor CLIs pick their own default model; the ruby_llm agent needs one for the provider.
        if adapter_name == "ruby_llm" && model.nil?
          model = Providers::DEFAULT_MODELS.fetch(provider.name) do
            raise Error, "set agent.model#{role ? " (or agent.roles.#{role}.model)" : ''} for the #{provider.name} provider"
          end
        end
        adapter = Adapters.build(adapter_name, provider:, model:, command: settings["command"], sandboxed: sandboxed?(project),
                                                           settings:)
        Agent.new(role: role&.to_s, adapter:, settings:)
      end
    end

    # An agent CLI with its role's settings: what it runs, and how its usage is costed.
    Agent = Data.define(:role, :adapter, :settings) do
      def label = adapter.label

      def provider = adapter.provider

      # Token usage from the CLI's output. CLIs that don't report cost get an estimate when
      # `pricing` (dollars per million input and output tokens) is configured.
      def usage(output)
        usage = adapter.parse_usage(output)
        pricing = settings["pricing"]
        return usage unless usage.cost_cents.zero? && pricing.is_a?(Hash)

        dollars = (usage.input_tokens * pricing["input_per_mtok"].to_f + usage.output_tokens * pricing["output_per_mtok"].to_f) / 1_000_000
        usage.with(cost_cents: (dollars * 100).ceil)
      end
    end

    def new_sandbox(image: nil, project: nil)
      return @sandbox_factory.call(image:) if @sandbox_factory
      return DryRun::Sandbox.new if dry_run?

      Sandbox.build(config["sandbox"].merge("mode" => sandbox_mode(project)), image:)
    end

    def committer(repo_name)
      Committer.new(repos.path(repo_name), limits: config["limits"],
                                           author_name: config.dig("git", "author_name"),
                                           author_email: config.dig("git", "author_email"))
    end

    def github = (@github ||= Integrations::GitHub.from_config(config["github"]))

    def jira = (@jira ||= Integrations::Jira.from_config(config["jira"]))

    # The credential handed to a role's agent container, under the name its CLI reads: an API key,
    # or else a subscription token (`claude setup-token`) for agents that accept one.
    def agent_key_env(role = nil, project: nil)
      agent = agent(role, project:)
      adapter = agent.adapter
      return {} unless adapter.key_env

      key = key_sources(agent, project:).lazy.filter_map { |name| present_env(name) }.first
      return { adapter.key_env => key } if key

      token = present_env(agent.settings["oauth_token_env"])
      token && adapter.oauth_env ? { adapter.oauth_env => token } : {}
    end

    # Host variables an agent's API key may come from, in order: the role's own key_env, the
    # provider's RUNEFORGE_<PROVIDER>_API_KEY, the general agent.key_env (only for the default
    # model's provider, so one key isn't sent to another provider), and on unsandboxed runs the
    # provider's own variable.
    def key_sources(agent, project: nil) = key_sources_for(agent.provider, agent.settings, project:)

    def key_sources_for(provider, settings, project: nil)
      sources = [settings["key_env"], "RUNEFORGE_#{provider.name.upcase.gsub(/[^A-Z0-9]/, '_')}_API_KEY"]
      sources << config.dig("agent", "key_env") if provider.name == default_provider_name
      sources << provider.key_var unless sandboxed?(project)
      sources.compact.uniq
    end

    # API keys run on Runeforge's ruby_llm agent. Claude models with only a Claude subscription
    # token run on Claude Code, which is what accepts one.
    def default_adapter(provider, settings, project: nil)
      return "ruby_llm" unless provider.name == "anthropic"

      key = key_sources_for(provider, settings, project:).any? { |name| present_env(name) }
      !key && present_env(settings["oauth_token_env"]) ? "claude_code" : "ruby_llm"
    end

    def default_provider_name
      base = config["agent"]
      Providers.split(base["model"], provider: base["provider"], adapter: base["adapter"]).first
    end

    # Stops before any work starts when a sandboxed agent would have nothing to log in with.
    # Unsandboxed agents use the person's own login; dry runs and `command` agents need nothing.
    def check_agent_credentials!(roles: %w[planner coder], project: nil)
      return if dry_run? || !sandboxed?(project)

      missing = roles.reject { |role| agent(role, project:).adapter.key_env.nil? || agent_key_env(role, project:).any? }
      raise Error, missing_credentials_message(missing.first, others: missing.drop(1), project:) if missing.any?
    end

    def missing_credentials_message(role = nil, others: [], project: nil)
      agent = agent(role, project:)
      who = role ? "The #{role}" : "The agent"
      also = others.any? ? " (and the #{others.join(', ')})" : ""
      model = agent.adapter.model_arg || "the default model"
      lines = ["#{who}#{also} has no credentials for #{model} (#{agent.provider.name}). Set one of these, then run again:"]
      key_sources(agent, project:).each do |name|
        lines << "  #{name}  an API key (best spend-limited), passed in as #{agent.adapter.key_env}"
      end
      # Claude models can also use a subscription token, which runs them on Claude Code.
      token = agent.settings["oauth_token_env"]
      if token && (agent.adapter.oauth_env || (agent.provider.name == "anthropic" && agent.settings["adapter"].nil?))
        lines << "  #{token}  a Claude subscription token from `claude setup-token` (runs on Claude Code)"
      end
      lines << "Already set one in your shell profile? It must be exported (`export NAME=...`) for runeforge to see it."
      lines.join("\n")
    end

    def present_env(name) = name && ENV[name].to_s.strip.then { |value| value.empty? ? nil : value }

    def logs_dir(task_id) = File.join(home, "logs", task_id.to_s).tap { |dir| FileUtils.mkdir_p(dir) }

    def workspaces_dir = File.join(home, "workspaces")
  end
end
