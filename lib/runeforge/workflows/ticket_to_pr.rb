# frozen_string_literal: true

module Runeforge
  module Workflows
    # Spec + acceptance tests -> code -> tests -> locked-test check -> push the branch (and a PR
    # for GitHub remotes). Foreground runs (tasks with a lane) also stop to ask the person at the
    # terminal for tools the sandbox is missing.
    TICKET_TO_PR = proc do
      on "task.created" do |task, msg|
        send_to :planner, "plan.request", sha: task[:base_sha], input: msg.payload
      end

      on "plan.done" do |_task, msg|
        lock_paths!(msg)
        apply_project!(msg)
        update_task(head_sha: msg.commit_sha)
        tools = Array(msg.payload.dig("project", "tools"))
        if interactive? && tools.any?
          send_to :operator, "deps.check", sha: msg.commit_sha, tools:, resume: "code"
        else
          send_to :coder, "code.request", sha: msg.commit_sha
        end
      end

      on "plan.failed" do |_task, msg|
        fail!("planning failed: #{msg.payload['reason']}")
      end

      on "deps.ready" do |_task, msg|
        if msg.payload["resume"] == "test"
          send_to :tester, "test.request", sha: msg.commit_sha
        else
          send_to :coder, "code.request", sha: msg.commit_sha
        end
      end

      on "deps.declined" do |_task, msg|
        fail!("missing tools: #{Array(msg.payload['missing']).join(', ')}")
      end

      on "code.done" do |_task, msg|
        send_to :tester, "test.request", sha: msg.commit_sha
      end

      on "code.failed" do |_task, msg|
        retry_or_fail(msg.payload)
      end

      on "test.result" do |_task, msg|
        missing = interactive? ? missing_commands(msg) : []
        if msg.payload["passed"]
          send_to :reviewer, "review.request", sha: msg.commit_sha
        elsif missing.any? && dependency_checks < 3
          send_to :operator, "deps.check", sha: msg.commit_sha, tools: missing, resume: "test"
        else
          retry_or_fail(msg.payload)
        end
      end

      on "review.verdict" do |_task, msg|
        if msg.payload["approved"]
          send_to :integrator, "integrate.request", sha: msg.commit_sha
        else
          retry_or_fail(msg.payload)
        end
      end

      on "integrate.done" do |_task, msg|
        complete!(external_pr_url: msg.payload["pr_url"])
      end

      on "integrate.failed" do |_task, msg|
        fail!("integration failed: #{msg.payload['reason']}")
      end

      on "task.retry" do |_task, msg|
        restart_from!(msg.commit_sha)
        send_to :coder, "code.request", sha: msg.commit_sha, feedback: "Restarted by a person from message #{msg.payload['from_message']}."
      end
    end
  end
end

Runeforge.workflow(:jira_to_pr, &Runeforge::Workflows::TICKET_TO_PR)
Runeforge.workflow(:build, &Runeforge::Workflows::TICKET_TO_PR)
Runeforge.workflow(:inbox, &Runeforge::Workflows::TICKET_TO_PR)
