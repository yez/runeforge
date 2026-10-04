# frozen_string_literal: true

require "socket"

module Runeforge
  # Reads results addressed to "supervisor", applies the task's workflow and sends the next
  # command. Also runs the lease reaper.
  class Supervisor
    COMMAND_STATUS = {
      "plan.request" => "planning",
      "code.request" => "coding",
      "test.request" => "testing",
      "review.request" => "reviewing",
      "deps.check" => "checking_dependencies",
      "integrate.request" => "integrating"
    }.freeze
    LLM_COMMANDS = %w[plan.request code.request].freeze

    attr_reader :env, :mailbox, :lane

    # With a lane, handles only that foreground run's results.
    def initialize(env, id: "supervisor@#{Socket.gethostname}:#{Process.pid}", lane: nil)
      @env = env
      @lane = lane
      @mailbox = env.mailbox(id)
    end

    def run(stop: -> { false })
      until stop.call
        sleep(env.config["poll_seconds"]) if tick.zero?
      end
    end

    # Reaps expired leases and handles every waiting result. Returns how many it handled.
    def tick
      mailbox.reap
      prune_events
      handled = 0
      while (msg = mailbox.claim(Runeforge.recipient(lane, "supervisor")))
        handle(msg)
        handled += 1
      end
      handled
    end

    PRUNE_EVERY = 600

    # Drops dashboard events older than events.retention_hours, at most every PRUNE_EVERY seconds.
    def prune_events
      return if @pruned_at && Runeforge.now - @pruned_at < PRUNE_EVERY

      @pruned_at = Runeforge.now
      Events.prune(env.db, before: @pruned_at - (env.config.dig("events", "retention_hours").to_f * 3600))
    end

    def handle(msg)
      mailbox.settle(msg) do
        task = env.tasks.find(msg.task_id)
        next if task.nil? || TERMINAL_STATUSES.include?(task[:status])

        workflow = Runeforge.workflows.fetch(task[:workflow]) { raise Error, "unknown workflow #{task[:workflow]}" }
        handler = workflow.handler_for(msg.type)
        next unless handler

        Context.new(env, mailbox, task, msg).instance_exec(task, msg, &handler)
      end
    rescue Mailbox::LeaseLost
      nil
    rescue StandardError => e
      mailbox.release(msg, error: "#{e.class}: #{e.message}")
    end

    # The helpers a workflow handler can call. Everything runs in the supervisor's transaction.
    class Context
      attr_reader :task, :msg

      def initialize(env, mailbox, task, msg)
        @env = env
        @mailbox = mailbox
        @task = task
        @msg = msg
      end

      def send_to(role, type, sha: nil, **payload)
        type = type.to_s
        if LLM_COMMANDS.include?(type) && (reason = budget_exhausted)
          return fail!(reason)
        end

        fields = { status: COMMAND_STATUS.fetch(type, task[:status]) }
        if type == "code.request"
          fields[:attempts] = task[:attempts] + 1
          payload[:attempt] = fields[:attempts]
        end
        @mailbox.post(
          task_id: task[:id], type:, recipient: Runeforge.recipient(task[:lane], role), payload:, in_reply_to: msg.id,
          commit_sha: sha, dedupe_key: "#{task[:id]}:#{type}:#{msg.id}"
        )
        update_task(fields)
      end

      # Sends the coder another attempt with the feedback, unless the task is out of budget.
      def retry_or_fail(feedback)
        text = feedback_text(feedback)
        limit = task[:attempts] >= task[:max_attempts] && "attempt limit reached (#{task[:attempts]}/#{task[:max_attempts]})"
        reason = budget_exhausted || limit
        return fail!("#{reason}. Last feedback: #{text[0, 500]}") if reason

        send_to(:coder, "code.request", sha: task[:head_sha], feedback: text)
      end

      # Adds the planner's tests to the locked set (earlier steps' tests stay locked).
      def lock_paths!(result)
        locked = JSON.parse(task[:locked_paths] || "{}").merge(result.payload.fetch("locked_paths", {}))
        update_task(spec: result.payload["spec"].to_s, locked_paths: JSON.generate(locked))
      end

      # Takes the test and setup commands from the plan when the repo doesn't have them yet.
      def apply_project!(result)
        project = result.payload["project"] || {}
        return if project.empty?

        repo = @env.repos.fetch(task[:repo])
        updates = %i[test_command setup_command].each_with_object({}) do |key, fields|
          value = project[key.to_s].to_s.strip
          fields[key] = value if repo[key].to_s.strip.empty? && !value.empty?
        end
        @env.repos.update(task[:repo], updates) if updates.any?
      end

      # Foreground runs have a person at the terminal who can answer dependency prompts.
      def interactive? = !task[:lane].nil?

      # Commands a failed test run couldn't find (exit status 127), e.g. "cargo: command not found".
      def missing_commands(result)
        return [] unless result.payload["exit_code"] == 127

        result.payload["output_tail"].to_s.scan(/([A-Za-z0-9][\w.+-]{0,63}): (?:command )?not found/).flatten.uniq
      end

      def dependency_checks = @env.db[:runeforge_messages].where(task_id: task[:id], type: "deps.check").count

      # Moves the task branch back to `sha` and drops anything in flight.
      def restart_from!(sha)
        @env.repos.reset_branch(task[:repo], branch: task[:branch], sha:)
        cancel_in_flight!
        update_task(head_sha: sha, error: nil)
      end

      def fail!(reason)
        cancel_in_flight!
        update_task(status: "failed", error: reason)
      end

      def complete!(**fields)
        update_task(fields.merge(status: "done", error: nil))
      end

      def update_task(fields)
        @env.tasks.update(task[:id], fields)
        @task = task.merge(fields)
      end

      private

      def budget_exhausted
        if task[:deadline_at] && Runeforge.now > task[:deadline_at]
          "deadline passed (#{task[:deadline_at].utc.iso8601})"
        elsif task[:token_budget] && task[:tokens_used] >= task[:token_budget]
          "token budget exhausted (#{task[:tokens_used]}/#{task[:token_budget]})"
        end
      end

      def cancel_in_flight!
        Events.cancel_messages(@env.db, @env.db[:runeforge_messages].where(task_id: task[:id]).exclude(id: msg.id))
      end

      def feedback_text(feedback)
        text =
          case feedback
          when Hash
            [feedback["reason"], Array(feedback["reasons"]).join("\n"), feedback["output_tail"]]
              .map(&:to_s).reject(&:empty?).join("\n\n")
          else
            feedback.to_s
          end
        limit = @env.config.dig("limits", "feedback_bytes")
        text.bytesize > limit ? text.byteslice(-limit, limit).scrub : text
      end
    end
  end
end
