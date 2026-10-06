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

    module_function

    # Why nothing ran, or nil. Exit 127 (command not found) is left to the dependency check.
    def nothing_ran(output, exit_code)
      return nil if exit_code.nil? || exit_code.zero? || exit_code == 127

      NOTHING_RAN.find { |pattern, _| output.to_s.match?(pattern) }&.last
    end
  end
end
