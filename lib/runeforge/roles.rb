# frozen_string_literal: true

module Runeforge
  module Roles
    def self.registry = (@registry ||= {})

    def self.register(name, klass)
      registry[name.to_s] = klass
    end

    def self.fetch(name)
      registry.fetch(name.to_s) { raise Error, "no handler for role #{name}" }
    end

    def self.names = registry.keys

    # Runs in the trusted worker process. Anything that executes agent-written code goes
    # through `sandbox`; everything read back from a workspace is treated as untrusted data.
    class Base
      # Dependency and build folders agents create by installing packages or running tests. They
      # never belong in a patch, whatever the project's .gitignore says.
      PATCH_EXCLUDES = %w[
        .runeforge/ node_modules/ .venv/ venv/ __pycache__/ *.pyc .pytest_cache/ .mypy_cache/ .ruff_cache/
        .tox/ vendor/bundle/ .bundle/ target/ .gradle/ .next/ .nuxt/ .turbo/ .cache/ coverage/
      ].freeze

      # Shell run inside the sandbox around the agent CLI. It snapshots the exported tree in a
      # throwaway repo, runs the agent, then writes everything it changed to .runeforge/changes.patch.
      AGENT_SCRIPT = <<~SH
        set -u
        mkdir -p "$HOME" 2>/dev/null
        g() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=runeforge -c user.email=runeforge@localhost "$@"; }
        { g init -q . && printf '%%s\\n' #{PATCH_EXCLUDES.map { |pattern| "'#{pattern}'" }.join(' ')} >> .git/info/exclude && g add -A && g commit -q --allow-empty -m runeforge-base; } >/dev/null 2>&1 \\
          || { echo "runeforge: could not initialise the workspace repository" >&2; exit 97; }
        base=$(g rev-parse HEAD)
        RUNEFORGE_PROMPT="$(cat .runeforge/prompt.md)"
        export RUNEFORGE_PROMPT
        ( %<command>s ) > .runeforge/agent.out 2> .runeforge/agent.err
        status=$?
        g add -A >/dev/null 2>&1
        g diff --cached --binary "$base" > .runeforge/changes.patch
        exit $status
      SH

      attr_reader :env, :msg, :sandbox, :task, :repo

      def self.call(env, msg, sandbox) = new(env, msg, sandbox).call

      def initialize(env, msg, sandbox)
        @env = env
        @msg = msg
        @sandbox = sandbox
        @task = env.tasks.find!(msg.task_id)
        @repo = env.repos.fetch(task[:repo])
      end

      private

      def result(type, payload = {}, commit_sha: nil, task_updates: {})
        { result_type: type, payload:, commit_sha:, task_updates: }
      end

      def limits = env.config["limits"]

      def with_workspace(sha, label)
        workspace = Workspace.create(root: env.workspaces_dir, name: "#{task[:id]}-#{label}")
        env.repos.export(task[:repo], sha:, to: workspace.path)
        yield workspace
      ensure
        workspace&.cleanup! unless env.config["keep_workspaces"]
      end

      AgentRun = Data.define(:result, :output, :usage, :log_path)

      def run_agent(workspace, prompt)
        workspace.write_meta("prompt.md", prompt)
        script = format(AGENT_SCRIPT, command: env.adapter.command)
        run = sandbox.run(workdir: workspace.path, script:, env: env.agent_key_env)
        output = workspace.read_meta("agent.out", max_bytes: limits["max_output_bytes"]).to_s
        errors = workspace.read_meta("agent.err", max_bytes: limits["max_output_bytes"]).to_s
        log = write_log(self.class.name.split("::").last.downcase,
                        [output, errors, run.stdout, run.stderr].reject(&:empty?).join("\n"))
        AgentRun.new(result: run, output:, usage: env.adapter.parse_usage(output), log_path: log)
      end

      def agent_failure(run)
        return "agent timed out" if run.result.timed_out
        return nil if run.result.exit_code.zero?

        "agent exited with status #{run.result.exit_code}: #{tail(run.result.stderr, 500)}"
      end

      def usage_updates(usage)
        { tokens_used: Sequel[:tokens_used] + usage.total_tokens, cost_cents: Sequel[:cost_cents] + usage.cost_cents }
      end

      def trailers(extra = {})
        { "Agent-Task" => task[:id], "Agent-Message" => msg.id }.merge(extra).merge("Agent-Model" => env.adapter.label)
      end

      def write_log(name, text)
        path = File.join(env.logs_dir(task[:id]), "#{msg.id}-#{name}.log")
        File.write(path, text)
        path
      end

      def locked_paths = JSON.parse(task[:locked_paths] || "{}")

      def tail(text, bytes)
        text = text.to_s
        text.bytesize > bytes ? text.byteslice(-bytes, bytes).scrub : text
      end
    end
  end
end

require_relative "roles/planner"
require_relative "roles/coder"
require_relative "roles/tester"
require_relative "roles/reviewer"
require_relative "roles/integrator"
