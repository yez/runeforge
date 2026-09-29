# frozen_string_literal: true

module Runeforge
  # Creates tasks from the CLI or a webhook. Ticket text is fetched here, on the host, because
  # containers never hold JIRA credentials.
  class Intake
    def initialize(env)
      @env = env
    end

    def create(repo:, workflow: "jira_to_pr", id: nil, ticket: nil, title: nil, description: nil)
      raise Error, "give a ticket or a spec" if ticket.nil? && title.nil? && description.nil?

      if ticket && description.nil? && @env.jira.configured?
        issue = @env.jira.issue(ticket)
        title ||= issue["title"]
        description = issue["description"]
      end
      title ||= ticket || description.to_s.lines.first.to_s.strip[0, 120]

      budgets = @env.config["budgets"]
      @env.tasks.create(
        id: id || ticket || "T-#{SecureRandom.hex(3)}",
        workflow:, repo:, title:, ticket:,
        base_sha: @env.repos.refresh(repo),
        mailbox: @env.mailbox("intake"),
        input: { "ticket" => ticket, "title" => title, "description" => description },
        max_attempts: budgets["max_attempts"],
        token_budget: budgets["token_budget"],
        deadline_at: budgets["max_task_minutes"] && (Runeforge.now + (budgets["max_task_minutes"] * 60))
      )
    end
  end
end
