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
                              feedback: msg.payload["feedback"])
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
        failed(e.message, run, updates || {})
      end

      def failed(reason, run, updates)
        result("code.failed", { "attempt" => attempt, "reason" => reason, "log_path" => run&.log_path }, task_updates: updates)
      end
    end

    register "coder", Coder
  end
end
