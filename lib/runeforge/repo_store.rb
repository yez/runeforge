# frozen_string_literal: true

module Runeforge
  # Host-owned bare clones. Agents never see these; they get exported copies.
  class RepoStore
    # A merge Runeforge won't make by itself: conflicts, or a checkout with uncommitted changes.
    class MergeBlocked < Error; end

    NAME_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/

    def initialize(db, root)
      @db = db
      @root = root
    end

    def table = @db[:runeforge_repos]

    def list = table.order(:name).all

    def fetch(name)
      table.where(name: name.to_s).first ||
        raise(Error, "unknown repo #{name}; add it with `runeforge repo add`")
    end

    def add(name:, url:, test_command:, base_branch: "main", image: nil, setup_command: nil)
      raise Error, "invalid repo name #{name.inspect}" unless name.to_s.match?(NAME_FORMAT)

      row = { url:, base_branch:, image:, test_command:, setup_command: }
      if table.where(name: name.to_s).count.positive?
        table.where(name: name.to_s).update(row)
      else
        table.insert(row.merge(name: name.to_s, created_at: Runeforge.now))
      end
      refresh(name)
    end

    def update(name, fields) = table.where(name: name.to_s).update(fields)

    def path(name) = File.join(@root, name.to_s)

    # Fetches the base branch and returns its current commit.
    def refresh(name)
      repo = fetch(name)
      ensure_clone(name, repo[:url])
      Git.run("fetch", "--quiet", "--prune", "origin", dir: path(name))
      base_sha(name)
    end

    def base_sha(name)
      branch = fetch(name)[:base_branch]
      Git.run("rev-parse", "--verify", "refs/remotes/origin/#{branch}^{commit}", dir: path(name)).strip
    end

    def export(name, sha:, to:) = Git.export(sha, dir: path(name), to:)

    # Object id of `file` at `sha`, or nil if it doesn't exist there.
    def oid(name, sha, file)
      Git.run("rev-parse", "--verify", "--quiet", "#{sha}:#{file}", dir: path(name), allow_failure: true)&.strip
    end

    def reset_branch(name, branch:, sha:)
      Git.run("update-ref", "refs/heads/#{branch}", sha, dir: path(name))
    end

    def push(name, branch:, sha:)
      Git.run("push", "--quiet", "origin", "+#{sha}:refs/heads/#{branch}", dir: path(name))
    end

    # Merges `sha` into the base branch on origin, for remotes without pull requests (local
    # directories, plain git servers). Fast-forwards when it can; otherwise builds the merge commit
    # here in the host clone, never touching a checkout, and gives up on conflicts. If origin is a
    # local repository with the base branch checked out, that checkout is fast-forwarded, but only
    # when it has no uncommitted changes. Returns the new tip of the base branch.
    def merge(name, sha:, message:, identity: {})
      repo = fetch(name)
      dir = path(name)
      Git.run("fetch", "--quiet", "--prune", "origin", dir:)
      tip = base_sha(name)
      return tip if ancestor?(dir, sha, tip) # already in the base branch

      result =
        if ancestor?(dir, tip, sha)
          sha
        else
          tree = Git.run("merge-tree", "--write-tree", tip, sha, dir:, allow_failure: true)
          raise MergeBlocked, "it conflicts with #{repo[:base_branch]}" unless tree

          Git.run("commit-tree", tree.lines.first.strip, "-p", tip, "-p", sha, "-m", message, dir:, env: identity).strip
        end
      deliver(repo, result)
      result
    end

    # Deletes a branch on origin and in the host clone, after its work was merged.
    def delete_branch(name, branch)
      Git.run("push", "--quiet", "origin", "--delete", branch, dir: path(name), allow_failure: true)
      Git.run("update-ref", "-d", "refs/heads/#{branch}", dir: path(name), allow_failure: true)
    end

    def changed_files(name, from:, to:)
      Git.run("diff", "--name-only", "--no-renames", "-z", from, to, dir: path(name)).split("\0")
    end

    # True when everything `sha` brings is already in `base`: merging it would change nothing.
    # Works however it was merged (merge commit, rebase, squash).
    def landed?(name, sha, base: base_sha(name))
      dir = path(name)
      return true if ancestor?(dir, sha, base)

      merged = Git.run("merge-tree", "--write-tree", base, sha, dir:, allow_failure: true)
      !merged.nil? && merged.lines.first.strip == Git.run("rev-parse", "#{base}^{tree}", dir:).strip
    end

    def contains?(name, sha, base: base_sha(name)) = ancestor?(path(name), sha, base)

    # Files under `dir` at `sha`: path => blob id.
    def files(name, sha, dir)
      Git.run("ls-tree", "-r", "-z", sha, "--", dir, dir: path(name)).split("\0").to_h do |entry|
        meta, file = entry.split("\t", 2)
        [file, meta.split(" ")[2]]
      end
    end

    def blob(name, id) = Git.run("cat-file", "blob", id, dir: path(name)).force_encoding(Encoding::UTF_8).scrub

    def exists?(name, sha, file) = !oid(name, sha, file).nil?

    def branch_sha(name, branch)
      Git.run("rev-parse", "--verify", "--quiet", "refs/heads/#{branch}^{commit}", dir: path(name), allow_failure: true)&.strip
    end

    private

    def ancestor?(dir, older, newer)
      !Git.run("merge-base", "--is-ancestor", older, newer, dir:, allow_failure: true).nil?
    end

    # Moves origin's base branch to `sha` without forcing. A non-bare local repository refuses a
    # push to its checked-out branch; then fast-forward that checkout instead.
    def deliver(repo, sha)
      branch = repo[:base_branch]
      Git.run("push", "--quiet", "origin", "#{sha}:refs/heads/#{branch}", dir: path(repo[:name]))
    rescue Git::CommandFailed => e
      raise unless e.message.include?("checked out") && File.directory?(repo[:url].to_s)

      fast_forward_checkout(repo, sha)
    end

    def fast_forward_checkout(repo, sha)
      work = repo[:url]
      branch = repo[:base_branch]
      unless Git.run("status", "--porcelain", "--untracked-files=no", dir: work).strip.empty?
        raise MergeBlocked, "#{work} has uncommitted changes on #{branch}"
      end

      Git.run("push", "--quiet", "--force", "origin", "#{sha}:refs/runeforge/merge", dir: path(repo[:name]))
      begin
        Git.run("merge", "--ff-only", "--quiet", "refs/runeforge/merge", dir: work)
      rescue Git::CommandFailed => e
        raise MergeBlocked, "could not fast-forward #{branch} in #{work}: #{e.message}"
      ensure
        Git.run("update-ref", "-d", "refs/runeforge/merge", dir: work, allow_failure: true)
      end
    end

    def ensure_clone(name, url)
      return if File.directory?(path(name))

      FileUtils.mkdir_p(@root)
      Git.run("clone", "--bare", "--quiet", url, path(name), dir: @root)
      # Bare clones have no fetch refspec; track the remote's branches under refs/remotes/origin.
      Git.run("config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*", dir: path(name))
    end
  end
end
