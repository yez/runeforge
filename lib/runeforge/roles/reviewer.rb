# frozen_string_literal: true

module Runeforge
  module Roles
    # Deterministic gate: every locked test file must be byte-for-byte what the planner committed.
    class Reviewer < Base
      def call
        sha = msg.commit_sha
        reasons = locked_paths.filter_map do |path, expected|
          actual = env.repos.oid(task[:repo], sha, path)
          "#{path} changed since planning" unless actual == expected
        end
        changed = env.repos.changed_files(task[:repo], from: task[:base_sha], to: sha)
        max_files = limits["max_files_changed"]
        reasons << "#{changed.size} files changed in total (limit #{max_files})" if changed.size > max_files

        result("review.verdict", { "approved" => reasons.empty?, "reasons" => reasons, "files_changed" => changed.size },
               commit_sha: sha)
      end
    end

    register "reviewer", Reviewer
  end
end
