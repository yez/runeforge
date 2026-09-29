# frozen_string_literal: true

module Runeforge
  module Roles
    # Runs the repository's own test command against a commit, in a fresh sandbox.
    class Tester < Base
      def call
        if repo[:test_command].to_s.strip.empty?
          return result("test.result", { "passed" => false, "exit_code" => nil, "reason" => "no test command is configured for #{repo[:name]}" },
                        commit_sha: msg.commit_sha)
        end

        with_workspace(msg.commit_sha, "test") do |workspace|
          script = [repo[:setup_command], repo[:test_command]].compact.reject(&:empty?).join(" && ")
          run = sandbox.run(workdir: workspace.path, script:, env: {})
          output = [run.stdout, run.stderr].reject(&:empty?).join("\n")
          passed = run.success?
          reason = passed ? nil : (run.timed_out ? "tests timed out" : "tests failed (exit status #{run.exit_code})")
          result("test.result",
                 { "passed" => passed, "exit_code" => run.exit_code, "timed_out" => run.timed_out, "reason" => reason,
                   "output_tail" => tail(output, limits["feedback_bytes"]), "log_path" => write_log("tester", output) },
                 commit_sha: msg.commit_sha)
        end
      end
    end

    register "tester", Tester
  end
end
