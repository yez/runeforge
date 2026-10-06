# frozen_string_literal: true

module Runeforge
  module Roles
    # Deterministic gate: every locked test file must be byte-for-byte what the planner committed.
    # It also checks the project's docs say how to run it (docs/run-conventions.md): blocking only
    # when Runeforge defined the run command itself (run_docs_required), a note otherwise, so a
    # project's own way of documenting its launch is never forced to change. For an Apple app
    # built on this Mac it also runs the run command and checks the app launches (LaunchCheck).
    class Reviewer < Base
      DOCS = %w[README.md readme.md Readme.md README.markdown README CONTRIBUTING.md].freeze

      def call
        sha = msg.commit_sha
        reasons = locked_paths.filter_map do |path, expected|
          actual = env.repos.oid(task[:repo], sha, path)
          "#{path} changed since planning" unless actual == expected
        end
        changed = env.repos.changed_files(task[:repo], from: task[:base_sha], to: sha)
        max_files = limits["max_files_changed"]
        reasons << "#{changed.size} files changed in total (limit #{max_files})" if changed.size > max_files
        notes = []
        if (problem = run_docs_problem(sha))
          repo[:run_docs_required] ? reasons << problem : notes << problem
        end
        # Only once everything else passed: it builds and launches the app, which takes minutes.
        if reasons.empty? && LaunchCheck.applies?(env, repo)
          outcome = with_workspace(sha, "launch") { |workspace| LaunchCheck.new(env, repo).call(workspace.path) }
          reasons.concat(outcome.reasons)
          notes << outcome.note if outcome.note
        end

        result("review.verdict", { "approved" => reasons.empty?, "reasons" => reasons, "notes" => notes,
                                   "files_changed" => changed.size }, commit_sha: sha)
      end

      private

      # Whether the README (or CONTRIBUTING.md, or a page under docs/) contains the run command.
      def run_docs_problem(sha)
        run_command = repo[:run_command].to_s.strip
        return nil if run_command.empty?

        texts = doc_files(sha).filter_map { |path| (oid = env.repos.oid(task[:repo], sha, path)) && env.repos.blob(task[:repo], oid) }
        squeeze = ->(text) { text.to_s.gsub(/\s+/, " ") }
        return nil if texts.any? { |text| squeeze.call(text).include?(squeeze.call(run_command)) }
        return "README.md is missing; add a How to run section with the install step and `#{run_command}`" if texts.empty?

        "README.md doesn't say how to run the project; its How to run section must include `#{run_command}`"
      end

      def doc_files(sha)
        docs = env.repos.files(task[:repo], sha, "docs").keys.select { |path| path.end_with?(".md") }.first(50)
        DOCS + docs
      end
    end

    register "reviewer", Reviewer
  end
end
