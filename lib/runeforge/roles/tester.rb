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
          run = sandbox.run(workdir: workspace.path, script: TestProbe.script(repo[:test_command]), env: TestProbe.env(repo[:setup_command]),
                            on_output: ->(chunk, stream) { output.write(chunk, stream:) })
          raw = [run.stdout, run.stderr].reject(&:empty?).join("\n")
          setup_failed = TestProbe.setup_failure(raw)
          output = TestProbe.clean(raw)
          passed = run.success?
          result("test.result",
                 { "passed" => passed, "exit_code" => run.exit_code, "timed_out" => run.timed_out,
                   "reason" => passed ? nil : reason(run, setup_failed), "setup_failed" => setup_failed,
                   "output_tail" => tail(output, limits["feedback_bytes"]), "warnings" => self.class.warnings(output, root: workspace.path),
                   "log_path" => write_log("tester", output) }.compact,
                 commit_sha: msg.commit_sha)
        end
      end
    end

    class Tester
      private

      # A setup command that fails isn't a failing test, and says so.
      def reason(run, setup_failed)
        return "tests timed out" if run.timed_out

        case setup_failed
        when "syntax" then "the setup command isn't valid shell, so no test ran: `#{repo[:setup_command].to_s[0, 200]}`"
        when "exit"
          "the setup command failed (exit status #{run.exit_code}) before any test ran. Your changes may have broken it " \
            "(a migration, the schema, a dependency); if the setup command itself is wrong, say so in .runeforge/contest.md"
        else "tests failed (exit status #{run.exit_code})"
        end
      end

      public

      # "Sources/X.swift:12:5: warning: ..." from swiftc and xcodebuild. Informational (passing is
      # still the exit status), but shown and handed to the coder: a Swift concurrency warning
      # went unseen until the app shipped with it.
      WARNING = /^(\S[^\n]*?\.swift:\d+(?::\d+)?: warning: .+?)\s*$/

      # Paths are made relative to the workspace (the repo), wherever the compiler printed them.
      def self.warnings(output, root: nil)
        text = output.to_s.scrub.gsub(TestProbe::ANSI, "")
        [root && File.realpath(root), root].compact.uniq.each { |dir| text = text.gsub("#{dir}/", "") } if root && File.directory?(root)
        text.scan(WARNING).flatten.uniq.first(10)
      end
    end

    register "tester", Tester
  end
end
