# frozen_string_literal: true

module Runeforge
  # Host-owned bare clones. Agents never see these; they get exported copies.
  class RepoStore
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

    def changed_files(name, from:, to:)
      Git.run("diff", "--name-only", "--no-renames", "-z", from, to, dir: path(name)).split("\0")
    end

    private

    def ensure_clone(name, url)
      return if File.directory?(path(name))

      FileUtils.mkdir_p(@root)
      Git.run("clone", "--bare", "--quiet", url, path(name), dir: @root)
      # Bare clones have no fetch refspec; track the remote's branches under refs/remotes/origin.
      Git.run("config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*", dir: path(name))
    end
  end
end
