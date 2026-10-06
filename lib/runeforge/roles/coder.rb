# frozen_string_literal: true

module Runeforge
  module Roles
    # Runs the coding agent on top of the given commit and commits its patch to the task branch.
    class Coder < Base
      def call
        sha = msg.commit_sha || task[:head_sha]
        with_workspace(sha, "a#{attempt}") { |workspace| code(workspace, sha) }
      end

      private

      def attempt = msg.payload.fetch("attempt", task[:attempts])

      def code(workspace, sha)
        prompt = Prompts.code(task:, attempt:, locked_paths: locked_paths.keys, test_command: repo[:test_command],
                              run_command: repo[:run_command], run_docs_required: repo[:run_docs_required] == true,
                              feedback: msg.payload["feedback"], apple: apple_toolchain)
        run = run_agent(workspace, prompt)
        updates = usage_updates(run.usage)
        failure = agent_failure(run)
        return failed(failure, run, updates) if failure

        patch = workspace.read_meta("changes.patch", max_bytes: limits["max_patch_bytes"])
        commit = env.committer(task[:repo]).commit(
          patch:, parent: sha, branch: task[:branch], locked: locked_paths.keys,
          message: Committer.message("runeforge: attempt #{attempt} for #{task[:id]}", trailers("Agent-Attempt" => attempt))
        )
        result("code.done", { "attempt" => attempt, "changed_paths" => commit.changed_paths, "log_path" => run.log_path },
               commit_sha: commit.sha, task_updates: updates.merge(head_sha: commit.sha))
      rescue Committer::PatchRejected, Workspace::UnsafeFile => e
        failed(only_meta_changes(workspace, e.message), run, updates || {})
      end

      # Kept so a coder that stops on purpose (e.g. the locked tests contradict each other) can be
      # heard: the supervisor hands it to the planner when the coder is stuck.
      SUMMARY_BYTES = 4000

      # Runeforge's own files in .runeforge/; anything else there was written by the agent.
      OWN_META = %w[prompt.md agent.out agent.err changes.patch agent.rb].freeze

      # "Made no changes" when the agent did change files, but only in .runeforge/ (never committed).
      def only_meta_changes(workspace, message)
        return message unless message == "the agent made no changes" && File.directory?(workspace.meta_dir)
        return message if File.symlink?(workspace.meta_dir)

        extra = Dir.children(workspace.meta_dir).sort - OWN_META
        return message if extra.empty?

        "the agent only changed files in .runeforge/ (#{extra.first(5).join(', ')}), which Runeforge never commits; " \
          "the tests and code must not depend on them"
      end

      def failed(reason, run, updates)
        summary = run && agent.adapter.summary(run.output)
        payload = { "attempt" => attempt, "reason" => reason, "log_path" => run&.log_path,
                    "summary" => summary&.byteslice(0, SUMMARY_BYTES)&.scrub }.compact
        result("code.failed", payload, task_updates: updates)
      end
    end

    register "coder", Coder
  end
end
