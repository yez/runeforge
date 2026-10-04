# frozen_string_literal: true

module Runeforge
  # Stand-ins for every role that go through the motions without calling an LLM, git, a
  # container runtime or the network. Each claims real messages, narrates its work as
  # agent.output events over a random 5-10 seconds (dry_run.min_seconds..max_seconds) and
  # replies with a plausible result, so the supervisor and workflow run unchanged. Some results
  # are failures (dry_run.failure_rate), so retries and failed tasks show up too.
  #
  # Turned on by `dry_run.enabled` in runeforge.yml, `runeforge worker --dry-run`, or
  # `runeforge demo`.
  module DryRun
    def self.fetch(role) = ROLES.fetch(role.to_s) { raise Error, "no dry-run handler for role #{role}" }

    # A sandbox that never runs anything. The worker's heartbeat calls kill when the lease or
    # task goes away; the role notices between steps and stops.
    class Sandbox
      attr_reader :id

      def initialize = @id = "dry-#{SecureRandom.hex(4)}"

      def run(**) = raise(Error, "dry run: nothing is executed")

      def kill = @killed = true

      def killed? = @killed == true
    end

    class Role
      attr_reader :env, :msg, :sandbox, :task

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
        @settings = env.config["dry_run"]
        @rng = Random.new
      end

      def output = (@output ||= OutputStream.new(env.db, msg, flush_seconds: 0.25))

      private

      # Says each line, spreading the steps over one random duration.
      def work(lines)
        total = @rng.rand(@settings["min_seconds"].to_f..@settings["max_seconds"].to_f)
        lines.each do |line|
          output.say(line)
          pause(total / lines.size)
        end
      end

      def pause(seconds)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        loop do
          raise Mailbox::LeaseLost, "dry run stopped: message #{msg.id} was cancelled or reclaimed" if sandbox.respond_to?(:killed?) && sandbox.killed?

          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if left <= 0

          sleep [left, 0.1].min
        end
      end

      def fails?(scale = 1.0) = @rng.rand < @settings["failure_rate"].to_f * scale

      def pick(list) = list[@rng.rand(list.size)]

      def fake_sha = SecureRandom.hex(20)

      def short(sha) = sha.to_s[0, 7]

      def slug = task[:id].downcase.gsub(/[^a-z0-9]+/, "_")

      def test_file = "spec/#{slug}_spec.rb"

      def result(type, payload = {}, commit_sha: nil, task_updates: {})
        { result_type: type, payload: payload.merge("dry_run" => true), commit_sha:, task_updates: }
      end

      # Pretend token spend, so budgets and cost counters move.
      def usage(tokens = @rng.rand(4_000..30_000))
        { tokens_used: Sequel[:tokens_used] + tokens, cost_cents: Sequel[:cost_cents] + (tokens * 0.0015).ceil }
      end
    end

    class Planner < Role
      def call
        work([
               "Reading ticket #{task[:id]}: #{task[:title]}",
               "Surveying the repository layout",
               "Found #{@rng.rand(2..6)} modules related to the change",
               "Drafting .runeforge/spec.md",
               "Writing acceptance tests: #{test_file}",
               "Adding scaffolding so the tests can run",
               "Locking 1 test file"
             ])
        return result("plan.failed", { "reason" => "simulated: the plan has no acceptance tests" }, task_updates: usage) if fails?(0.2)

        sha = fake_sha
        spec = "## #{task[:title]}\n\nSimulated spec written by a dry-run planner. No model was called."
        result("plan.done", { "spec" => spec, "locked_paths" => { test_file => fake_sha }, "project" => {} },
               commit_sha: sha, task_updates: usage)
      end
    end

    class Coder < Role
      FILES = %w[lib/app.rb lib/app/models/report.rb lib/app/exporter.rb lib/app/cli.rb config/routes.rb
                 lib/app/services/sync.rb lib/app/views/index.html.erb].freeze

      def call
        attempt = msg.payload.fetch("attempt", task[:attempts])
        files = FILES.sample(@rng.rand(1..3), random: @rng)
        lines = ["Attempt #{attempt}: checking out #{short(msg.commit_sha || task[:head_sha])}"]
        lines << "Reading feedback: #{msg.payload['feedback'].to_s.lines.first.to_s.strip[0, 80]}" if msg.payload["feedback"]
        lines += ["Reading the spec and #{test_file}", *files.map { |file| "Editing #{file}" },
                  "Running a quick syntax check",
                  "Writing the patch: #{files.size} files, +#{@rng.rand(10..200)} -#{@rng.rand(0..60)}"]
        work(lines)
        if fails?(0.5)
          return result("code.failed", { "attempt" => attempt, "reason" => "simulated: agent exited with status 1" },
                        task_updates: usage)
        end

        sha = fake_sha
        result("code.done", { "attempt" => attempt, "changed_paths" => files }, commit_sha: sha,
                                                                                task_updates: usage.merge(head_sha: sha))
      end
    end

    class Tester < Role
      def call
        examples = @rng.rand(12..80)
        passed = !fails?(2.0)
        work([
               "Starting a fresh sandbox for #{short(msg.commit_sha)}",
               "Running setup: bundle install",
               "Running the test suite: #{examples} examples",
               "#{'.' * [examples / 2, 40].min}",
               "#{'.' * [examples / 3, 30].min}#{passed ? '' : 'F'}",
               passed ? "#{examples} examples, 0 failures" : "#{examples} examples, 1 failure"
             ])
        tail = passed ? "#{examples} examples, 0 failures" : "Failure: #{test_file}:#{@rng.rand(5..60)}\nexpected 3 rows, got 2\n#{examples} examples, 1 failure"
        result("test.result",
               { "passed" => passed, "exit_code" => passed ? 0 : 1, "timed_out" => false,
                 "reason" => passed ? nil : "tests failed (exit status 1)", "output_tail" => tail },
               commit_sha: msg.commit_sha)
      end
    end

    class Reviewer < Role
      def call
        changed = @rng.rand(2..9)
        approved = !fails?(0.3)
        work([
               "Comparing locked test files with the plan",
               approved ? "#{test_file} is unchanged" : "#{test_file} differs from the planned version",
               "Counting changed files: #{changed} (limit #{env.config.dig('limits', 'max_files_changed')})",
               approved ? "Approved" : "Rejected"
             ])
        reasons = approved ? [] : ["#{test_file} changed since planning"]
        result("review.verdict", { "approved" => approved, "reasons" => reasons, "files_changed" => changed },
               commit_sha: msg.commit_sha)
      end
    end

    class Integrator < Role
      def call
        number = @rng.rand(100..999)
        work([
               "Pushing #{short(msg.commit_sha)} to #{task[:branch]}",
               "Looking for an open pull request",
               "Opening pull request ##{number}",
               "Done"
             ])
        if fails?(0.1)
          return result("integrate.failed", { "reason" => "simulated: push rejected (non-fast-forward)" }, commit_sha: msg.commit_sha)
        end

        url = "dry-run://pull/#{number}"
        result("integrate.done", { "pr_url" => url, "branch" => task[:branch], "warnings" => [] },
               commit_sha: msg.commit_sha, task_updates: { external_pr_url: url })
      end
    end

    class Operator < Role
      def call
        work(["Checking the sandbox for #{Array(msg.payload['tools']).join(', ')}", "All tools available"])
        result("deps.ready", { "tools" => msg.payload["tools"], "resume" => msg.payload["resume"] }, commit_sha: msg.commit_sha)
      end
    end

    ROLES = {
      "planner" => Planner, "coder" => Coder, "tester" => Tester, "reviewer" => Reviewer,
      "integrator" => Integrator, "operator" => Operator
    }.freeze
  end
end
