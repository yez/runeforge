# frozen_string_literal: true

module Runeforge
  # Host-side git. Every call disables hooks and fsmonitor, because the repositories hold
  # content written by agents.
  module Git
    class CommandFailed < Error; end

    SAFE_FLAGS = [
      "-c", "core.hooksPath=/dev/null",
      "-c", "core.fsmonitor=false",
      "-c", "protocol.ext.allow=never"
    ].freeze

    module_function

    def run(*args, dir:, env: {}, stdin: nil, allow_failure: false)
      out, err, status = Open3.capture3(
        { "GIT_TERMINAL_PROMPT" => "0" }.merge(env), "git", *SAFE_FLAGS, *args.map(&:to_s),
        chdir: dir, stdin_data: stdin, binmode: true
      )
      return out if status.success?
      return nil if allow_failure

      raise CommandFailed, "git #{args.first(2).join(' ')} failed: #{err.strip}"
    end

    # Writes the tree at `sha` into `dest` without checking anything out in the host repo.
    def export(sha, dir:, to:)
      statuses = Open3.pipeline(
        ["git", *SAFE_FLAGS, "archive", "--format=tar", sha.to_s, { chdir: dir, err: File::NULL }],
        ["tar", "-xf", "-", "-C", to.to_s, { err: File::NULL }]
      )
      raise CommandFailed, "could not export #{sha} into #{to}" unless statuses.all?(&:success?)
    end
  end
end
