# frozen_string_literal: true

module Runeforge
  module Roles
    # Pushes the approved commit, opens the PR, and (unless manual_merge is set) merges it into the
    # base branch, using credentials that only exist on the host. GitHub merges go through the PR;
    # other remotes are merged directly. A merge that's refused (branch protection, conflicts, a
    # dirty checkout) leaves the branch for a person and is reported, not treated as a failure.
    # Safe to repeat: the push is idempotent, an existing PR is reused, and merged work is detected.
    class Integrator < Base
      def call
        sha = msg.commit_sha || task[:head_sha]
        env.repos.push(task[:repo], branch: task[:branch], sha:)
        pr_url = task[:external_pr_url] || env.github.find_or_create_pull(
          repo_url: repo[:url], head: task[:branch], base: repo[:base_branch], title: pull_title, body: pull_body
        )
        warnings = []
        warnings << comment_on_ticket(pr_url) if task[:ticket] && pr_url && env.jira.configured?
        merged = merge(sha, warnings)
        result("integrate.done",
               { "pr_url" => pr_url, "branch" => task[:branch], "base" => repo[:base_branch], "merged" => !merged.nil?,
                 "merged_sha" => merged, "warnings" => warnings.compact },
               commit_sha: sha, task_updates: { external_pr_url: pr_url, merged_sha: merged })
      rescue Error => e
        result("integrate.failed", { "reason" => e.message }, commit_sha: sha)
      end

      private

      # Returns the base branch commit that took in the work, or nil when it wasn't merged.
      def merge(sha, warnings)
        return nil if env.config["manual_merge"]
        return task[:merged_sha] if task[:merged_sha]

        if Integrations::GitHub.slug(repo[:url])
          env.github.merge_pull(repo_url: repo[:url], head: task[:branch], sha:, method: env.config["merge_method"],
                                title: pull_title)
        else
          merged = env.repos.merge(task[:repo], sha:, message: merge_message, identity:)
          env.repos.delete_branch(task[:repo], task[:branch])
          merged
        end
      rescue Integrations::HTTPError, RepoStore::MergeBlocked, Git::CommandFailed => e
        warnings << "not merged into #{repo[:base_branch]}: #{e.message}; the work is on #{task[:branch]}"
        nil
      end

      def pull_title = "#{task[:ticket] ? "#{task[:ticket]}: " : ''}#{task[:title]}"

      def merge_message
        Committer.message("Merge #{task[:branch]}: #{pull_title}", { "Agent-Task" => task[:id] })
      end

      def identity
        name = env.config.dig("git", "author_name")
        email = env.config.dig("git", "author_email")
        { "GIT_AUTHOR_NAME" => name, "GIT_AUTHOR_EMAIL" => email, "GIT_COMMITTER_NAME" => name, "GIT_COMMITTER_EMAIL" => email }
      end

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
