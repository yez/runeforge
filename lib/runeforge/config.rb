# frozen_string_literal: true

require "yaml"

module Runeforge
  # Settings from runeforge.yml. Repositories live in the database (`runeforge repo add`).
  #
  # Runeforge is a command you install, so its settings live with its data in ~/.runeforge, not in
  # whichever directory it's run from. -c PATH or RUNEFORGE_CONFIG points somewhere else.
  class Config
    GLOBAL_PATH = File.join(Dir.home, ".runeforge", "runeforge.yml")
    # Where `runeforge init` used to write when run from a checkout; ignored now (see .stray_config).
    LEGACY_PATH = "runeforge.yml"

    def self.locate(explicit = nil)
      explicit ||= ENV.fetch("RUNEFORGE_CONFIG", nil)
      explicit.to_s.strip.empty? ? GLOBAL_PATH : File.expand_path(explicit)
    end

    # Written by `runeforge config edit` when there is no config yet. Everything is optional.
    STARTER = <<~YAML
      # Runeforge settings. Every option is documented in runeforge.yml.example (in the gem's
      # source); anything left out uses its default. Secrets are read from environment
      # variables, never from this file.

      # agent:
      #   model: claude-sonnet-5-5          # or gemini-pro-latest, gpt-5.6, deepseek-v4-pro, openrouter/...
      #   roles:
      #     planner: { model: gemini-pro-latest }

      # sandbox:
      #   mode: docker                      # docker | podman | none (agents run any command as you)

      # manual_merge: false                 # true: leave branches and pull requests unmerged

      # workers:
      #   - planner,coder
      #   - tester,reviewer,integrator
    YAML

    # What's wrong with a config file, as sentences; empty when it's fine (or doesn't exist).
    def self.problems(path)
      return [] unless File.exist?(path)

      data = YAML.safe_load_file(path, aliases: true)
      return [] if data.nil?
      return ["#{path} must be a YAML mapping of settings (key: value)"] unless data.is_a?(Hash)

      problems = (data.keys.map(&:to_s) - DEFAULTS.keys).map { |key| "unknown setting `#{key}`" }
      problems += project_problems(data["projects"]) if data.key?("projects")
      agent = data["agent"]
      return problems unless agent.is_a?(Hash)

      roles = agent["roles"].is_a?(Hash) ? agent["roles"] : {}
      problems << "`agent.roles` must be a mapping of role names to settings" if agent.key?("roles") && !agent["roles"].is_a?(Hash)
      problems += (roles.keys.map(&:to_s) - %w[planner coder]).map { |role| "`agent.roles.#{role}`: only planner and coder use a model" }
      [["agent", agent], *roles.map { |role, settings| ["agent.roles.#{role}", settings] }].each do |where, settings|
        adapter = settings.is_a?(Hash) && settings["adapter"]
        next unless adapter && !Adapters.names.include?(adapter.to_s)

        hint = adapter.to_s == "gemini" ? " (the Gemini CLI is deprecated; remove it, Gemini models run on ruby_llm)" : ""
        problems << "`#{where}.adapter`: unknown agent #{adapter.to_s.inspect}#{hint}; use one of #{Adapters.names.join(', ')}"
      end
      problems
    rescue Psych::SyntaxError => e
      ["#{path} is not valid YAML: #{e.problem} at line #{e.line}, column #{e.column}"]
    end

    # Settings that can differ per project (see "projects" in DEFAULTS).
    PROJECT_KEYS = %w[manual_merge merge_method sandbox launch_check].freeze
    MERGE_METHODS = %w[merge squash rebase].freeze
    SANDBOX_MODES = %w[docker podman none].freeze

    def self.project_problems(projects)
      return ["`projects` must be a mapping of project (repo name, directory or git URL) to settings"] unless projects.is_a?(Hash)

      projects.flat_map do |project, settings|
        next ["`projects.#{project}` must be a mapping of settings"] unless settings.is_a?(Hash)

        found = (settings.keys.map(&:to_s) - PROJECT_KEYS).map { |key| "`projects.#{project}.#{key}`: only #{PROJECT_KEYS.join(', ')} can be set per project" }
        if settings.key?("manual_merge") && ![true, false].include?(settings["manual_merge"])
          found << "`projects.#{project}.manual_merge` must be true or false"
        end
        if settings.key?("launch_check") && ![true, false].include?(settings["launch_check"])
          found << "`projects.#{project}.launch_check` must be true or false"
        end
        if settings.key?("merge_method") && !MERGE_METHODS.include?(settings["merge_method"].to_s)
          found << "`projects.#{project}.merge_method` must be one of #{MERGE_METHODS.join(', ')}"
        end
        if settings.key?("sandbox") && !SANDBOX_MODES.include?(settings["sandbox"].to_s)
          found << "`projects.#{project}.sandbox` must be one of #{SANDBOX_MODES.join(', ')} (none runs agents and tests on this machine)"
        end
        found
      end
    end

    # A runeforge.yml in the current directory that isn't being used, to point out.
    def self.stray_config(in_use)
      path = File.expand_path(LEGACY_PATH)
      File.exist?(path) && path != in_use ? path : nil
    end

    DEFAULTS = {
      "database" => nil, # defaults to sqlite at <home>/runeforge.db
      "home" => "~/.runeforge",
      "lease_seconds" => 300,
      "heartbeat_seconds" => 30,
      "poll_seconds" => 2,
      "max_deliveries" => 3,
      "keep_workspaces" => false,
      "budgets" => {
        "max_attempts" => 5,
        "token_budget" => nil,
        "max_task_minutes" => 240
      },
      "sandbox" => {
        # "docker" (default), "podman", or "none" for trusted local use.
        "mode" => "docker",
        "image" => "runeforge/general:latest",
        "network" => "bridge",
        "cpus" => 2,
        "memory" => "4g",
        "pids" => 512,
        "timeout_seconds" => 1800
      },
      "agent" => {
        # The model, as "name" or "provider/name" (e.g. claude-sonnet-5-5, gemini-pro-latest, gpt-5,
        # openrouter/qwen/qwen3-coder). Nil uses the agent CLI's own default.
        "model" => nil,
        # Inferred from the model; set it for providers Runeforge doesn't know (see Providers).
        "provider" => nil,
        # What drives the model: ruby_llm (Runeforge's own agent, for API keys from any provider),
        # claude_code (also takes a Claude subscription token), codex, aider, or command (runs
        # `command` as a shell snippet). Nil: ruby_llm, or claude_code when the only credential is
        # a Claude subscription token.
        "adapter" => nil,
        "command" => nil,
        # Host variable holding the API key for the default model's provider. Each provider's key
        # can also live in RUNEFORGE_<PROVIDER>_API_KEY (e.g. RUNEFORGE_GEMINI_API_KEY).
        "key_env" => "RUNEFORGE_LLM_API_KEY",
        # Variable name the agent CLI reads inside the container; defaults per provider.
        "container_key_env" => nil,
        # Host variable holding a Claude subscription token (`claude setup-token`), used when no API
        # key is set. Claude Code only.
        "oauth_token_env" => "CLAUDE_CODE_OAUTH_TOKEN",
        # Dollars per million tokens, when the agent can't price the model: { input_per_mtok, output_per_mtok }.
        "pricing" => nil,
        # ruby_llm agent only: an API endpoint (e.g. an OpenAI-compatible service with provider:
        # openai), and how many tool calls one run may make before it's stopped.
        "api_base" => nil,
        "max_tool_calls" => 200,
        # Per-role overrides of any setting above, e.g. { "planner" => { "model" => "gemini-pro-latest" } }.
        "roles" => {}
      },
      "limits" => {
        "max_patch_bytes" => 2_000_000,
        "max_files_changed" => 200,
        "max_spec_bytes" => 65_536,
        "max_output_bytes" => 1_000_000,
        "feedback_bytes" => 4_000,
        # The reviewer's launch check (an Apple app's setup + run command, see LaunchCheck).
        "launch_check_seconds" => 600
      },
      "test_globs" => [
        "spec/**/*", "test/**/*", "tests/**/*", "__tests__/**/*", "**/__tests__/**/*",
        "**/*_test.*", "**/*_spec.*", "**/test_*.*", "**/*.test.*", "**/*.spec.*",
        # Swift (SwiftPM Tests/, Xcode AppTests/ and AppUITests/), Android and the JVM, .NET
        "Tests/**/*", "**/*Tests/**/*", "**/*Tests.swift", "**/*Test.swift",
        "**/src/test/**/*", "**/src/androidTest/**/*", "**/*Test.kt", "**/*Test.java",
        "**/*Tests.cs", "**/*Test.cs"
      ],
      "git" => {
        "author_name" => "Runeforge",
        "author_email" => "runeforge@localhost"
      },
      "github" => {
        "token_env" => "GITHUB_TOKEN",
        "api_url" => "https://api.github.com"
      },
      "jira" => {
        "url" => nil,
        "email_env" => "JIRA_EMAIL",
        "token_env" => "JIRA_API_TOKEN",
        "webhook_secret_env" => "RUNEFORGE_WEBHOOK_SECRET",
        "trigger_label" => "runeforge",
        "project_repos" => {},
        "default_repo" => nil
      },
      "workflow_paths" => [],
      # Each finished task is merged into the repository's base branch: through the pull request
      # on GitHub (merge_method: merge, squash or rebase), directly for other remotes. true leaves
      # branches and pull requests for a person to merge.
      "manual_merge" => false,
      # Before merging an Apple app built on this Mac, run its run command and check the app
      # launches and keeps running on the simulator (it opens the simulator window briefly).
      "launch_check" => true,
      # Plans committed to a project's runeforge/inbox/ are queued and built in order (see
      # Runeforge::Inbox). The supervisor checks each registered repository this often.
      "inbox" => {
        "enabled" => true,
        "poll_seconds" => 60
      },
      "merge_method" => "merge",
      # Per-project overrides of the settings in PROJECT_KEYS, keyed by the project's registered
      # repo name, its directory, or its git URL:
      #   projects: { "~/code/payments": { manual_merge: true } }
      "projects" => {},
      # Agents that go through the motions (sleeps and canned output) without calling an LLM,
      # git or the network. See Runeforge::DryRun.
      "dry_run" => {
        "enabled" => false,
        "min_seconds" => 5,
        "max_seconds" => 10,
        "failure_rate" => 0.15
      },
      # The runeforge_events feed behind the dashboard. Older events are pruned by the supervisor.
      "events" => {
        "retention_hours" => 24
      },
      # Background processes started by `runeforge up`: one supervisor plus one worker per entry.
      "workers" => ["planner,coder", "tester,reviewer,integrator"]
    }.freeze

    # A missing file means "use the defaults" unless must_exist is set.
    def self.load(path = GLOBAL_PATH, overrides = {}, must_exist: false)
      data =
        if path && File.exist?(path)
          YAML.safe_load_file(path, aliases: true) || {}
        elsif must_exist
          raise Error, "config file not found: #{path}"
        else
          {}
        end
      merged = deep_merge(deep_merge(DEFAULTS, data), overrides)
      merged["database"] ||= "sqlite://#{File.join(File.expand_path(merged['home']), 'runeforge.db')}"
      new(merged)
    end

    def self.deep_merge(base, other)
      base.merge(other.transform_keys(&:to_s)) do |_key, a, b|
        a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b
      end
    end

    def initialize(data)
      @data = data
    end

    def [](key) = @data.fetch(key.to_s)

    def dig(*keys) = @data.dig(*keys.map(&:to_s))

    def home = File.expand_path(self["home"])

    # A project-level setting (PROJECT_KEYS) for a registered repo: its entry under `projects`
    # if one matches the repo's name, directory or git URL, else the top-level value.
    def for_project(repo, key)
      key = key.to_s
      raise ArgumentError, "#{key} can't be set per project" unless PROJECT_KEYS.include?(key) && key != "sandbox"

      entry = repo && project_entry(repo)
      entry&.key?(key) ? entry[key] : self[key]
    end

    # A project's sandbox mode (docker, podman or none): `projects.<project>.sandbox`, else
    # `sandbox.mode`. An iOS app, which Linux containers can't build, sets `sandbox: none` so its
    # agents and tests run on the Mac with Xcode.
    def sandbox_mode_for(repo)
      (repo && project_entry(repo)&.dig("sandbox")) || dig("sandbox", "mode")
    end

    def project_entry(repo)
      names = [repo[:name], repo[:url]].compact.map(&:to_s)
      local = repo[:url].to_s.start_with?("/", "~") ? normalize_path(repo[:url]) : nil
      (self["projects"] || {}).find do |project, _settings|
        project = project.to_s
        names.any? { |name| same_url?(name, project) } || (local && normalize_path(project) == local)
      end&.last
    end

    def normalize_path(path) = File.expand_path(path.to_s).chomp("/")

    def same_url?(a, b) = a.chomp("/").delete_suffix(".git") == b.chomp("/").delete_suffix(".git")

    def to_h = @data
  end
end
