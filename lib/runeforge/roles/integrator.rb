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
        @queued = []
        sha = bookkeeping(msg.commit_sha || task[:head_sha])
        return nothing_to_merge(sha) if !task[:merged_sha] && env.repos.contains?(task[:repo], sha)

        env.repos.push(task[:repo], branch: task[:branch], sha:)
        pr_url = task[:external_pr_url] || env.github.find_or_create_pull(
          repo_url: repo[:url], head: task[:branch], base: repo[:base_branch], title: pull_title, body: pull_body
        )
        warnings = []
        warnings << comment_on_ticket(pr_url) if task[:ticket] && pr_url && env.jira.configured?
        merged = merge(sha, warnings)
        result("integrate.done",
               { "pr_url" => pr_url, "branch" => task[:branch], "base" => repo[:base_branch], "merged" => !merged.nil?,
                 "merged_sha" => merged, "warnings" => warnings.compact, "queued" => queued_note }.compact,
               commit_sha: sha, task_updates: { external_pr_url: pr_url, merged_sha: merged, head_sha: sha })
      rescue Error => e
        result("integrate.failed", { "reason" => e.message }, commit_sha: sha)
      end

      private

      # A step an earlier one already built, with nothing of its own (see Roles::Planner): its
      # commit is already in the base branch, so there's no branch to push or pull request to open.
      def nothing_to_merge(sha)
        result("integrate.done", { "branch" => task[:branch], "base" => repo[:base_branch], "merged" => true,
                                   "merged_sha" => sha, "warnings" => [], "queued" => queued_note }.compact,
               commit_sha: sha, task_updates: { merged_sha: sha, head_sha: sha })
      end

      # Returns the base branch commit that took in the work, or nil when it wasn't merged.
      def merge(sha, warnings)
        return nil if env.manual_merge?(task[:repo])
        return task[:merged_sha] if task[:merged_sha]

        if Integrations::GitHub.slug(repo[:url])
          env.github.merge_pull(repo_url: repo[:url], head: task[:branch], sha:, method: env.merge_method(task[:repo]),
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

      # Runeforge's own commits on the task branch, merged along with the work: the runeforge/ folder
      # for repositories that don't have one yet, and moving a finished inbox plan to done/.
      def bookkeeping(sha)
        return sha unless env.config.dig("inbox", "enabled")

        committer = env.committer(task[:repo])
        unless env.repos.exists?(task[:repo], sha, Inbox::INBOX)
          sha = committer.host_commit(parent: sha, branch: task[:branch], write: Inbox.scaffold,
                                      message: Committer.message("runeforge: add the inbox folder", bookkeeping_trailers))
        end
        plan = input["plan"]
        sha = queue_discoveries(committer, sha, plan) if plan
        return sha unless plan && plan["last"]

        delete = env.repos.exists?(task[:repo], sha, plan["path"]) ? [plan["path"]] : []
        write = { done_path(sha, plan) => done_record(plan) }
        # Git drops a folder with no files, so moving out an inbox's last plan would remove the inbox.
        keep = "#{Inbox::INBOX}/.gitkeep"
        write[keep] = "" unless env.repos.exists?(task[:repo], sha, keep)
        committer.host_commit(parent: sha, branch: task[:branch], delete:, write:,
                              message: Committer.message("runeforge: #{plan['name']} is done", bookkeeping_trailers))
      end

      def bookkeeping_trailers = { "Agent-Task" => task[:id], "Agent-Message" => msg.id }

      # Work the step's agents found outside it, queued as inbox plans that wait for this plan
      # (see Ledger#discoveries! for what's checked first). Committed with the step's work.
      def queue_discoveries(committer, sha, plan)
        found = env.db[:runeforge_messages].where(task_id: task[:id], type: %w[plan.done code.done]).order(:id).all.flat_map do |row|
          message = Message.from_row(row)
          Array(message.payload.dig("handoff", "discovered")).map { |entry| entry.merge("by" => message.type.split(".").first) }
        end
        return sha if found.empty?

        row = env.db[:runeforge_plans].where(id: plan["id"]).first
        meta = row ? PlanFile.parse(env.repos.blob(task[:repo], row[:blob])).meta : {}
        exists = file_at(sha)
        @queued = env.ledger.discoveries!(task, found, plan_meta: meta, exists: ->(path) { !exists.call(path).nil? })
        return sha if @queued.empty?

        write = @queued.to_h do |entry|
          slug = Build.slug(entry[:title]).then { |s| s.empty? ? "found" : s }
          ["#{Inbox::INBOX}/found-#{slug}-#{entry[:id][-6..]}.md", discovered_plan(entry, plan)]
        end
        committer.host_commit(parent: sha, branch: task[:branch], write:,
                              message: Committer.message("runeforge: queue #{write.size} found while building #{task[:id]}", bookkeeping_trailers))
      rescue Error => e
        warn "runeforge: couldn't queue discovered work for #{task[:id]}: #{e.message}"
        sha
      end

      def discovered_plan(entry, plan)
        <<~MD
          ---
          title: #{entry[:title].gsub(/[\r\n:#]/, ' ').strip}
          after: #{plan['name']}
          discovered_from: #{task[:id]}
          ---

          # #{entry[:title]}

          - [ ] #{entry[:title]}
            #{entry[:why].to_s.gsub(/\s+/, ' ').strip}
            Evidence: #{entry[:evidence].to_s.gsub(/\s+/, ' ').strip}

          Found by Runeforge's agents while building `#{task[:id]}` (ledger item `#{entry[:id]}`). Delete this file to drop it.
        MD
      end

      def queued_note
        return nil if @queued.to_a.empty?

        @queued.map { |entry| { "title" => entry[:title], "evidence" => entry[:evidence], "found_in" => task[:id] } }
      end

      def input
        @input ||= Message.parse_payload(env.db[:runeforge_messages].where(task_id: task[:id], type: "task.created").get(:payload) || "{}")
      end

      def done_path(sha, plan)
        path = "#{Inbox::DONE}/#{plan['name']}.md"
        env.repos.exists?(task[:repo], sha, path) ? "#{Inbox::DONE}/#{plan['name']}-#{plan['id']}.md" : path
      end

      # The plan as it was run, with a footer of what Runeforge did with it.
      def done_record(plan)
        row = env.db[:runeforge_plans].where(id: plan["id"]).first
        text = row ? env.repos.blob(task[:repo], row[:blob]) : ""
        ids = row ? JSON.parse(row[:task_ids] || "[]") : [task[:id]]
        tasks = env.db[:runeforge_tasks].where(id: ids).all.sort_by { |t| ids.index(t[:id]) }
        lines = tasks.map do |t|
          "- `#{t[:id]}`: #{t[:title]} (#{t[:attempts]} attempt#{'s' unless t[:attempts] == 1}, #{t[:tokens_used]} tokens, " \
            "branch `#{t[:branch]}`#{t[:merged_sha] ? ", merged as #{t[:merged_sha][0, 7]}" : ''})"
        end
        "#{text.rstrip}\n\n---\n\nBuilt by Runeforge, #{Runeforge.now.utc.strftime('%Y-%m-%d %H:%M UTC')}:\n\n#{lines.join("\n")}\n"
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
