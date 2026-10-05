# frozen_string_literal: true

module Runeforge
  # Turns an agent's patch into a commit in the host's bare clone. The patch is applied to a
  # temporary index, so nothing is ever checked out on the host and the agent never touches
  # the host's .git directory.
  class Committer
    class PatchRejected < Error; end

    Commit = Data.define(:sha, :changed_paths)

    def initialize(repo_path, limits:, author_name:, author_email:)
      @repo_path = repo_path
      @limits = limits
      @author_env = {
        "GIT_AUTHOR_NAME" => author_name, "GIT_AUTHOR_EMAIL" => author_email,
        "GIT_COMMITTER_NAME" => author_name, "GIT_COMMITTER_EMAIL" => author_email
      }
    end

    def self.message(subject, trailers)
      "#{subject}\n\n#{trailers.map { |key, value| "#{key}: #{value}" }.join("\n")}\n"
    end

    # locked: paths the patch may not change. allow: optional predicate every changed path must pass.
    # validate: optional block given the changed paths; raise PatchRejected to refuse the commit.
    def commit(patch:, parent:, branch:, message:, locked: [], allow: nil, validate: nil)
      patch = patch.to_s
      raise PatchRejected, "the agent made no changes" if patch.strip.empty?
      if patch.bytesize > @limits.fetch("max_patch_bytes")
        raise PatchRejected, "patch is #{patch.bytesize} bytes (limit #{@limits.fetch('max_patch_bytes')})"
      end

      Dir.mktmpdir("runeforge-index") do |tmp|
        index_env = { "GIT_INDEX_FILE" => File.join(tmp, "index") }
        patch_file = File.join(tmp, "changes.patch")
        File.binwrite(patch_file, patch)

        git("read-tree", parent, env: index_env)
        apply(patch_file, index_env)
        tree = git("write-tree", env: index_env).strip
        changed = git("diff-tree", "-r", "--name-only", "--no-renames", "-z", "#{parent}^{tree}", tree).split("\0")

        check!(changed, locked:, allow:)
        validate&.call(changed)
        sha = git("commit-tree", tree, "-p", parent, "-F", "-", env: @author_env, stdin: message).strip
        git("update-ref", "refs/heads/#{branch}", sha)
        Commit.new(sha:, changed_paths: changed)
      end
    end

    # A commit Runeforge makes itself, not from an agent's patch: writes or deletes whole files on
    # top of `parent` and moves `branch`. Used for the inbox's bookkeeping (see Inbox).
    def host_commit(parent:, branch:, message:, write: {}, delete: [])
      Dir.mktmpdir("runeforge-index") do |tmp|
        index_env = { "GIT_INDEX_FILE" => File.join(tmp, "index") }
        git("read-tree", parent, env: index_env)
        # --index-info works in a bare repository; mode 0 removes an entry.
        entries = delete.map { |path| "0 #{'0' * 40}\t#{path}" }
        entries += write.map do |path, content|
          "100644 #{git('hash-object', '-w', '--stdin', stdin: content).strip}\t#{path}"
        end
        git("update-index", "--index-info", env: index_env, stdin: entries.map { |line| "#{line}\n" }.join) if entries.any?
        tree = git("write-tree", env: index_env).strip
        return parent if tree == git("rev-parse", "#{parent}^{tree}").strip

        sha = git("commit-tree", tree, "-p", parent, "-F", "-", env: @author_env, stdin: message).strip
        git("update-ref", "refs/heads/#{branch}", sha)
        sha
      end
    end

    private

    def apply(patch_file, env)
      git("apply", "--cached", "--binary", "--whitespace=nowarn", patch_file, env:)
    rescue Git::CommandFailed => e
      raise PatchRejected, "patch does not apply: #{e.message}"
    end

    def check!(changed, locked:, allow:)
      raise PatchRejected, "the agent made no changes" if changed.empty?

      max_files = @limits.fetch("max_files_changed")
      raise PatchRejected, "patch changes #{changed.size} files (limit #{max_files})" if changed.size > max_files

      [Workspace::META_DIR, Inbox::DIR].each do |dir|
        hits = changed.select { |path| path == dir || path.start_with?("#{dir}/") }
        raise PatchRejected, "patch touches #{dir}/: #{hits.join(', ')}" if hits.any?
      end

      touched = changed & locked
      raise PatchRejected, "patch changes locked test files: #{touched.join(', ')}" if touched.any?

      return unless allow

      disallowed = changed.reject { |path| allow.call(path) }
      raise PatchRejected, "patch changes files outside the allowed paths: #{disallowed.join(', ')}" if disallowed.any?
    end

    def git(*args, env: {}, stdin: nil) = Git.run(*args, dir: @repo_path, env:, stdin:)
  end
end
