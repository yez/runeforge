# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require "securerandom"
require "open3"
require "tmpdir"
require "sequel"

module Runeforge
  class Error < StandardError; end

  TERMINAL_STATUSES = %w[done failed cancelled].freeze

  def self.now = Time.now.utc

  # Recipients are a role ("coder") or, for a foreground run's lane, "<lane>/<role>".
  def self.recipient(lane, role) = lane ? "#{lane}/#{role}" : role.to_s

  def self.role_of(recipient) = recipient.to_s.split("/").last

  def self.lane_of(recipient) = recipient.to_s.include?("/") ? recipient.to_s.split("/").first : nil

  def self.workflows = (@workflows ||= {})

  def self.workflow(name, &block)
    workflows[name.to_s] = Workflow.new(name.to_s, &block)
  end

  # Process-wide environment for embedded use (jobs, webhook app). The CLI builds its own.
  def self.environment
    @environment ||= Environment.load(config_path: Config.locate(ENV.fetch("RUNEFORGE_CONFIG", nil)))
  end

  def self.environment=(env)
    @environment = env
  end
end

require_relative "runeforge/version"
require_relative "runeforge/config"
require_relative "runeforge/db"
require_relative "runeforge/git"
require_relative "runeforge/message"
require_relative "runeforge/events"
require_relative "runeforge/mailbox"
require_relative "runeforge/output_stream"
require_relative "runeforge/tasks"
require_relative "runeforge/repo_store"
require_relative "runeforge/workspace"
require_relative "runeforge/committer"
require_relative "runeforge/sandbox"
require_relative "runeforge/providers"
require_relative "runeforge/adapters"
require_relative "runeforge/prompts"
require_relative "runeforge/integrations/http"
require_relative "runeforge/integrations/github"
require_relative "runeforge/integrations/jira"
require_relative "runeforge/plan_file"
require_relative "runeforge/test_probe"
require_relative "runeforge/platform"
require_relative "runeforge/launch_check"
require_relative "runeforge/inbox"
require_relative "runeforge/intake"
require_relative "runeforge/environment"
require_relative "runeforge/workflow"
require_relative "runeforge/supervisor"
require_relative "runeforge/roles"
require_relative "runeforge/worker"
require_relative "runeforge/dry_run"
require_relative "runeforge/demo"
require_relative "runeforge/workflows/ticket_to_pr"
require_relative "runeforge/daemons"
require_relative "runeforge/setup"
require_relative "runeforge/operator"
require_relative "runeforge/build_progress"
require_relative "runeforge/build"
require_relative "runeforge/implode"
