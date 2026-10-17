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
        .tox/ vendor/bundle/ .bundle/ target/ .gradle/ .next/ .nuxt/ .turbo/ .cache/ coverage/ .aider*
      ].freeze

      # New untracked directories and files over these sizes are left out of patches.
      SKIP_DIR_KB = 5 * 1024
      SKIP_FILE_KB = 1024

      # Shell run inside the sandbox around the agent CLI. It snapshots the exported tree in a
      # throwaway repo, runs the agent, then writes everything it changed to .runeforge/changes.patch.
      AGENT_SCRIPT = <<~SH
        set -u
        mkdir -p "$HOME" 2>/dev/null
        # The project's setup command (Tailwind, the test database, dependencies) runs before the
        # agent starts, and before the base commit so what it changes stays out of the patch.
        if [ -n "${RUNEFORGE_SETUP:-}" ]; then
          ( eval "$RUNEFORGE_SETUP" ) > .runeforge/setup.out 2>&1
          setup_status=$?
          if [ "$setup_status" -ne 0 ]; then
            {
              printf '\\n## The setup command failed\\n'
              printf 'Runeforge ran `%%s` before you started and it exited with status %%s. ' "$RUNEFORGE_SETUP" "$setup_status"
              printf 'Its output is in .runeforge/setup.out: read it and fix what you can before running the tests.\\n'
            } >> .runeforge/prompt.md
          fi
        fi
        g() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=runeforge -c user.email=runeforge@localhost "$@"; }
        { g init -q . && printf '%%s\\n' #{PATCH_EXCLUDES.map { |pattern| "'#{pattern}'" }.join(' ')} >> .git/info/exclude && g add -A && g commit -q --allow-empty -m runeforge-base; } >/dev/null 2>&1 \\
          || { echo "runeforge: could not initialise the workspace repository" >&2; exit 97; }
        base=$(g rev-parse HEAD)
        RUNEFORGE_PROMPT="$(cat .runeforge/prompt.md)"
        export RUNEFORGE_PROMPT
        ( %<command>s ) > .runeforge/agent.out 2> .runeforge/agent.err
        status=$?
        # Big new directories and files the run downloaded or generated (a browser for system tests,
        # build output) stay out of the patch; .runeforge/skipped lists them, with their size in KB.
        : > .runeforge/skipped
        skip() { printf '/%%s\\n' "${1%%/}" >> .git/info/exclude; printf '%%s %%s\\n' "$1" "$2" >> .runeforge/skipped; }
        g ls-files -z --others --exclude-standard --directory | tr '\\0' '\\n' | while IFS= read -r path; do
          [ -d "$path" ] || continue
          kb=$(du -sk "$path" 2>/dev/null | cut -f1)
          [ "${kb:-0}" -gt #{SKIP_DIR_KB} ] && skip "$path" "$kb"
        done
        g ls-files -z --others --exclude-standard | tr '\\0' '\\n' | while IFS= read -r path; do
          [ -f "$path" ] || continue
          kb=$(( $(wc -c < "$path") / 1024 ))
          [ "$kb" -gt #{SKIP_FILE_KB} ] && skip "$path" "$kb"
        done
        g add -A >/dev/null 2>&1
        g diff --cached --binary "$base" > .runeforge/changes.patch
        exit $status
      SH

      attr_reader :env, :msg, :sandbox, :task, :repo

      # What the agent's run left out of its patch (see AGENT_SCRIPT): "chrome/ (270 MB)".
      def skipped(workspace)
        workspace.read_meta_text("skipped", max_bytes: 16_384).to_s.lines(chomp: true).first(20).filter_map do |line|
          path, kb = line.rpartition(" ").values_at(0, 2)
          next if path.empty?

          "#{path} (#{kb.to_i >= 1024 ? "#{kb.to_i / 1024} MB" : "#{kb} KB"})"
        end
      rescue Workspace::UnsafeFile
        []
      end

      def self.call(env, msg, sandbox)
        role = new(env, msg, sandbox)
        role.call
      ensure
        role&.output&.close
      end

      def initialize(env, msg, sandbox)
        @env = env
        @msg = msg
        @sandbox = sandbox
        @task = env.tasks.find!(msg.task_id)
        @repo = env.repos.fetch(task[:repo])
      end

      # Live output for the dashboard (agent.output events).
      def output = (@output ||= OutputStream.new(env.db, msg))

      private

      def result(type, payload = {}, commit_sha: nil, task_updates: {})
        { result_type: type, payload:, commit_sha:, task_updates: }
      end

      def limits = env.config["limits"]

      # The Apple toolchain to describe to the agents (Prompts.apple_section): only for an Apple
      # project built on this machine. The planner passes the platform it just detected.
      def apple_toolchain(platform = repo[:platform])
        return nil unless platform == "apple" && !env.sandboxed?(repo) && !env.dry_run?

        Platform.apple_toolchain
      end

      def with_workspace(sha, label)
        workspace = Workspace.create(root: env.workspaces_dir, name: "#{task[:id]}-#{label}")
        env.repos.export(task[:repo], sha:, to: workspace.path)
        yield workspace
      ensure
        workspace&.cleanup! unless env.config["keep_workspaces"]
      end

      # This role's name and its agent CLI (see Environment#agent).
      def role = Runeforge.role_of(msg.recipient)

      def agent = env.agent(role, project: repo)

      AgentRun = Data.define(:result, :output, :errors, :usage, :log_path)

      # conversation: the Conversations row this run continues (or just started), or nil for a run
      # of its own.
      # setup: the project's setup command, run in the workspace before the agent starts.
      def run_agent(workspace, prompt, conversation: nil, setup: nil)
        workspace.write_meta("prompt.md", prompt)
        agent.adapter.files.each { |name, content| workspace.write_meta(name, content) }
        script = format(AGENT_SCRIPT, command: agent.adapter.command)
        # The agent's output goes to files in the workspace; follow them while it runs.
        files = { "stdout" => File.join(workspace.meta_dir, "agent.out"), "stderr" => File.join(workspace.meta_dir, "agent.err") }
        run_env = env.agent_key_env(role, project: repo).merge(agent.adapter.run_env).merge(TestProbe.env(setup))
        restored = conversation ? hand_over(conversation, workspace, run_env) : []
        sessions = conversation && agent.adapter.name == "claude_code" ? env.conversations.sessions_dir(conversation) : nil
        run = output.follow(files) { sandbox.run(workdir: workspace.path, script:, env: run_env, sessions:) }
        output = workspace.read_meta("agent.out", max_bytes: limits["max_output_bytes"]).to_s
        errors = workspace.read_meta("agent.err", max_bytes: limits["max_output_bytes"]).to_s
        log = write_log(self.class.name.split("::").last.downcase,
                        [output, errors, run.stdout, run.stderr].reject(&:empty?).join("\n"))
        usage = agent.usage(output)
        usage = keep(conversation, workspace, output, usage, restored) if conversation
        AgentRun.new(result: run, output:, errors:, usage:, log_path: log)
      end

      # Conversations (agent.conversation: step) for the agents that can continue one.
      def conversations? = env.config.dig("agent", "conversation") == "step" && CONVERSING.include?(agent.adapter.name)

      CONVERSING = %w[claude_code ruby_llm].freeze

      # Whether the conversation already has something to continue from.
      def continuing?(conversation)
        return false unless conversation

        agent.adapter.name == "claude_code" ? !conversation[:session_id].nil? : env.conversations.messages(conversation).any?
      end

      # Gives the run the conversation so far: Claude Code's session to resume, or the ruby_llm
      # agent's transcript in its workspace. Returns the messages handed over.
      def hand_over(conversation, workspace, run_env)
        if agent.adapter.name == "claude_code"
          run_env["RUNEFORGE_RESUME"] = conversation[:session_id] if conversation[:session_id]
          return []
        end

        messages = env.conversations.messages(conversation)
        workspace.write_meta("conversation.json", JSON.generate(messages)) if messages.any?
        messages
      end

      # Records what the run added to the conversation, and returns its usage with a resumed Claude
      # Code session's cost cut down to this run's share.
      def keep(conversation, workspace, output, usage, restored)
        if agent.adapter.name == "claude_code"
          id = agent.adapter.session_id(output)
          return usage unless id

          added = env.conversations.record_session(conversation, session_id: id, cost_usd: agent.adapter.reported_cost_usd(output))
          return usage.with(cost_cents: (added * 100).ceil)
        end

        raw = workspace.read_meta_text("conversation.out.json", max_bytes: limits["max_conversation_bytes"])
        env.conversations.append(conversation, JSON.parse(raw).drop(restored.size), message_id: msg.id) if raw
        usage
      rescue JSON::ParserError, Error, Workspace::UnsafeFile
        usage # a transcript that can't be read just isn't kept; the next run starts from what was
      end

      # Nil when the agent ran cleanly. Otherwise the CLI's own explanation (Claude Code reports
      # errors such as "Not logged in" in its JSON output), else the end of its stderr.
      def agent_failure(run)
        return "agent timed out" if run.result.timed_out

        detail = agent.adapter.failure_detail(run.output, run.errors)
        return nil if run.result.exit_code.zero? && detail.nil?

        detail ||= tail([run.errors, run.result.stderr].reject(&:empty?).join("\n").strip, 500)
        hint = detail.match?(/log ?in|authenticat|401|api.?key|oauth|permission denied/i) ? " (#{env.missing_credentials_message(role, project: repo).lines.drop(1).map(&:strip).join('; ')})" : ""
        "agent #{run.result.exit_code.zero? ? 'reported an error' : "exited with status #{run.result.exit_code}"}: #{detail}#{hint}"
      end

      def usage_updates(usage)
        { tokens_used: Sequel[:tokens_used] + usage.total_tokens, cost_cents: Sequel[:cost_cents] + usage.cost_cents }
      end

      def trailers(extra = {})
        { "Agent-Task" => task[:id], "Agent-Message" => msg.id }.merge(extra).merge("Agent-Model" => agent.label)
      end

      def write_log(name, text)
        path = File.join(env.logs_dir(task[:id]), "#{msg.id}-#{name}.log")
        File.write(path, text)
        path
      end

      def locked_paths = JSON.parse(task[:locked_paths] || "{}")

      # ->(path) { the file's text at the commit, or nil }, for checking an agent's handoff.
      def file_at(sha)
        cache = {}
        lambda do |path|
          path = path.to_s.strip.delete_prefix("./")
          next nil if path.empty? || path.start_with?("/") || path.split("/").include?("..")

          cache.fetch(path) { cache[path] = (oid = env.repos.oid(task[:repo], sha, path)) && env.repos.blob(task[:repo], oid) }
        rescue Git::CommandFailed
          nil
        end
      end

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
require_relative "roles/ux_reviewer"
require_relative "roles/integrator"
