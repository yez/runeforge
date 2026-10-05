# frozen_string_literal: true

require "yaml"

module Runeforge
  # Global settings from runeforge.yml. Repositories live in the database (`runeforge repo add`).
  class Config
    DEFAULT_PATH = "runeforge.yml"
    GLOBAL_PATH = File.join(Dir.home, ".runeforge", "runeforge.yml")

    # An explicit path wins; otherwise ./runeforge.yml if present, else ~/.runeforge/runeforge.yml.
    def self.locate(explicit = nil)
      return File.expand_path(explicit) if explicit

      File.exist?(DEFAULT_PATH) ? File.expand_path(DEFAULT_PATH) : GLOBAL_PATH
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
        # claude_code, codex, aider, or command (runs `command` as a shell snippet).
        "adapter" => "claude_code",
        "model" => nil,
        "command" => nil,
        # Host variable holding the spend-limited key that is passed into containers.
        "key_env" => "RUNEFORGE_LLM_API_KEY",
        # Variable name the agent CLI reads inside the container; defaults per adapter.
        "container_key_env" => nil
      },
      "limits" => {
        "max_patch_bytes" => 2_000_000,
        "max_files_changed" => 200,
        "max_spec_bytes" => 65_536,
        "max_output_bytes" => 1_000_000,
        "feedback_bytes" => 4_000
      },
      "test_globs" => [
        "spec/**/*", "test/**/*", "tests/**/*", "__tests__/**/*", "**/__tests__/**/*",
        "**/*_test.*", "**/*_spec.*", "**/test_*.*", "**/*.test.*", "**/*.spec.*"
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
      # Plans committed to a project's runeforge/inbox/ are queued and built in order (see
      # Runeforge::Inbox). The supervisor checks each registered repository this often.
      "inbox" => {
        "enabled" => true,
        "poll_seconds" => 60
      },
      "merge_method" => "merge",
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
    def self.load(path = DEFAULT_PATH, overrides = {}, must_exist: false)
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

    def to_h = @data
  end
end
