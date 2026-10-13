# frozen_string_literal: true

module Runeforge
  # Recognises a test run where no tests ran at all: the command couldn't find or load them. The
  # planner probes its own test command with this, so a command that can never pass (like
  # `node --test tests/` on Node 22, which tries to load the directory as a module) fails the plan
  # instead of costing the coder every attempt. Failing tests are fine; that's the point of a plan.
  module TestProbe
    NOTHING_RAN = [
      [%r{Cannot find module '/workspace/(?:tests?|spec|specs|__tests__)/?'}, "the test runner tried to load the test directory as a module"],
      [/^# tests 0$/, "node --test found no tests"],
      [/\bno tests ran\b|\bcollected 0 items\b/, "pytest found no tests"],
      [/\b0 examples, 0 failures\b/, "rspec found no examples"],
      [/\bNo tests found\b/, "the test runner found no tests"],
      [/\bno test files\b/, "go test found no test files"],
      [/\bExecuted 0 tests\b/, "XCTest ran no tests"],
      [/^running 0 tests$/, "cargo test ran no tests"]
    ].freeze

    # Compiled stacks build the whole test target before running anything, so one missing type
    # stops every test, the earlier steps' locked ones included. A plan like that hasn't checked a
    # single assertion; tests that contradict the locked ones then only show up after coding.
    BUILD_FAILED = [
      # Not xcodebuild's "** TEST FAILED **": it also ends a run whose tests built and then failed.
      [/^error: (?:Build failed|fatalError)\b|^\*\* BUILD FAILED \*\*|Testing cancelled because the build failed/,
       "the Swift test target doesn't compile"],
      [/^error: could not compile `/, "cargo couldn't compile the tests"],
      [/^\s*\[build failed\]|^FAIL\s+\S+\s+\[(?:build|setup) failed\]/, "go test couldn't build the package"],
      [/Compilation (?:error|failed)|Execution failed for task ':[\w:-]*compile\w*'/, "Gradle couldn't compile the tests"],
      [/^Build FAILED\.|: error CS\d{4}:/, "dotnet couldn't build the tests"]
    ].freeze
    ANSI = /\e\[[0-9;]*m/
    SETUP_FAILED = "__RUNEFORGE_SETUP_FAILED__"

    module_function

    # The script that runs a project's tests: the setup command (passed as $RUNEFORGE_SETUP, see
    # .env), then the test command, in one shell so setup's exports reach the tests. A setup
    # command that doesn't parse, or fails, is marked so it isn't mistaken for failing tests
    # (see .setup_failure).
    def script(test_command)
      <<~SH
        if [ -n "${RUNEFORGE_SETUP:-}" ]; then
          if ! syntax=$(sh -n -c "$RUNEFORGE_SETUP" 2>&1); then
            printf '%s\n\n%s syntax\n' "$syntax" "#{SETUP_FAILED}" >&2
            exit 2
          fi
          eval "$RUNEFORGE_SETUP"
          status=$?
          if [ "$status" -ne 0 ]; then
            printf '\n%s %s\n' "#{SETUP_FAILED}" "$status" >&2
            exit "$status"
          fi
        fi
        #{test_command}
      SH
    end

    def env(setup_command) = setup_command.to_s.strip.empty? ? {} : { "RUNEFORGE_SETUP" => setup_command.to_s.strip }

    # "syntax" when the setup command isn't valid shell, "exit" when it failed, or nil.
    def setup_failure(output) = output.to_s[/^#{SETUP_FAILED} (\S+)$/, 1]&.then { |kind| kind == "syntax" ? "syntax" : "exit" }

    # The run's output without the setup marker.
    def clean(output) = output.to_s.gsub(/\n*^#{SETUP_FAILED} \S+\n?/, "\n").rstrip

    # Why nothing ran, or nil. Exit 127 (command not found) is left to the dependency check.
    def nothing_ran(output, exit_code)
      return nil if exit_code.nil? || exit_code.zero? || exit_code == 127

      NOTHING_RAN.find { |pattern, _| output.to_s.match?(pattern) }&.last
    end

    # Why the tests didn't build, or nil.
    def build_failed(output, exit_code)
      return nil if exit_code.nil? || exit_code.zero? || exit_code == 127

      text = output.to_s.scrub.gsub(ANSI, "")
      BUILD_FAILED.find { |pattern, _| text.match?(pattern) }&.last
    end
  end
end
