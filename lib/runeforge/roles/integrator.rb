# frozen_string_literal: true

module Runeforge
  module Roles
    # Pushes the approved commit and opens the PR, using credentials that only exist on the host.
    # Safe to repeat: the push is idempotent and an existing PR is reused.
    class Integrator < Base
      def call
        sha = msg.commit_sha || task[:head_sha]
        env.repos.push(task[:repo], branch: task[:branch], sha:)
        pr_url = task[:external_pr_url] || env.github.find_or_create_pull(
          repo_url: repo[:url], head: task[:branch], base: repo[:base_branch],
          title: "#{task[:ticket] ? "#{task[:ticket]}: " : ''}#{task[:title]}", body: pull_body
        )
        warnings = []
        warnings << comment_on_ticket(pr_url) if task[:ticket] && pr_url && env.jira.configured?
        result("integrate.done", { "pr_url" => pr_url, "branch" => task[:branch], "warnings" => warnings.compact },
               commit_sha: sha, task_updates: { external_pr_url: pr_url })
      rescue Error => e
        result("integrate.failed", { "reason" => e.message }, commit_sha: sha)
      end

      private

      def pull_body
        <<~BODY
          Opened by Runeforge for task `#{task[:id]}`#{task[:ticket] ? " (#{task[:ticket]})" : ''}.

          ## Spec
          #{task[:spec]}

          ## Acceptance tests
          #{locked_paths.keys.map { |path| "- `#{path}`" }.join("\n")}

          Attempts: #{task[:attempts]}. Tokens: #{task[:tokens_used]}.
        BODY
      end

      def comment_on_ticket(pr_url)
        env.jira.comment(task[:ticket], "Runeforge opened a pull request: #{pr_url}")
        nil
      rescue Error => e
        "could not comment on #{task[:ticket]}: #{e.message}"
      end
    end

    register "integrator", Integrator
  end
end
