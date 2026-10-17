# frozen_string_literal: true

module Runeforge
  # `runeforge doctor -d DIR`, and the check `runeforge build -d` and `resume -d` make before they
  # touch the inbox: can this project's agents and tests actually run? Everything is checked in
  # the sandbox the agents will use (the same image, user, variables and services), in the order
  # each depends on the one before, and every problem comes with what to do about it. A plan
  # never starts, and so never fails, while a check fails.
  class Doctor
    Check = Data.define(:name, :status, :detail, :fix) do
      def failed? = status == :failed
    end

    class NotReady < Error; end

    ICONS = { ok: "✓", warning: "!", failed: "✗", skipped: "-" }.freeze
    # The program each agent adapter runs inside the sandbox.
    AGENT_CLIS = { "ruby_llm" => "ruby", "claude_code" => "claude", "codex" => "codex", "aider" => "aider" }.freeze
    PROBE = <<~SH
      printf 'ruby=%s\\n' "$(ruby -e 'print RUBY_VERSION' 2>/dev/null)"
      printf 'node=%s\\n' "$(node -p 'process.versions.node' 2>/dev/null)"
      for cli in #{AGENT_CLIS.values.uniq.join(' ')}; do command -v "$cli" >/dev/null 2>&1 && printf 'cli=%s\\n' "$cli"; done
      exit 0
    SH
    LOW_DISK_GB = 10

    attr_reader :checks

    def initialize(env, repo_name, directory:, shell: Setup::Shell.new, out: $stdout)
      @env = env
      @repo_name = repo_name
      @directory = directory
      @shell = shell
      @out = out
      @checks = []
    end

    def ready? = checks.none?(&:failed?)

    # Runs every check and prints them; raises NotReady (with what to do) unless they all pass.
    def run!
      @out.puts "Checking the build environment for #{@directory}"
      run
      return self if ready?

      raise NotReady, "the build environment isn't ready, so nothing was started and no plan was changed. " \
                      "Fix what's marked ✗ above, then run the same command again (`runeforge doctor -d #{@directory}` checks without building)."
    end

    def run
      @checks = []
      sandboxed = %w[docker podman].include?(@env.sandbox_mode(repo))
      sandboxed ? container_checks : host_checks
      credentials_check
      checkout_check
      embeddings_check
      # A project waiting on its environment can go again once it checks out (see Inbox).
      @env.repos.update(@repo_name, platform_status: nil, platform_note: nil) if ready? && repo[:platform_status] == "incompatible"
      self
    end

    private

    def repo = @env.repos.fetch(@repo_name)

    def runtime = @env.sandbox_mode(repo)

    def check(name, status, detail, fix = nil)
      @checks << Check.new(name:, status:, detail:, fix:)
      @out.puts format("  %s %-14s %s", ICONS.fetch(status), name, detail)
      @out.puts "      fix: #{fix}" if fix
      status != :failed
    end

    def container_checks
      runtime_check && disk_check && image_check && container_check && services_check
    end

    def runtime_check
      unless @shell.which(runtime)
        return check(runtime, :failed, "`#{runtime}` isn't installed or isn't on PATH",
                     "install #{runtime == 'docker' ? 'Docker Desktop' : 'Podman'} and make sure `#{runtime}` runs in this shell, " \
                     "or set `sandbox: none` for this project under `projects:` in #{Config.locate}")
      end
      version = @shell.capture(runtime, "version", "--format", "{{.Server.Version}}").strip
      return check(runtime, :ok, "running (#{version})") unless version.empty?

      check(runtime, :failed, "#{runtime} isn't running, or isn't responding",
            "start #{runtime == 'docker' ? 'Docker Desktop' : '`podman machine start`'}, wait until `#{runtime} info` works, then run again")
    end

    # A full disk is how Docker's storage breaks (I/O errors that look like anything else).
    def disk_check
      kb = @shell.capture("df", "-Pk", @env.home).lines.last.to_s.split[3].to_i
      return true if kb.zero?

      gb = kb / 1024 / 1024
      return check("disk", :ok, "#{gb} GB free") if gb >= LOW_DISK_GB

      check("disk", :warning, "only #{gb} GB free; images and builds need room, and a full disk breaks #{runtime}",
            "free space, or remove unused images with `#{runtime} system prune`")
    end

    def image_check
      status, detail = Devcontainer.ensure_image(@env, @repo_name, shell: @shell, out: @out)
      image = repo[:image] || @env.config.dig("sandbox", "image")
      case status
      when :ok then check("project image", :ok, "#{image}#{detail.start_with?('built') ? ' (built just now)' : ''}")
      when :skipped then check("project image", :ok, "#{image} (#{detail.sub(/;.*/, '')})")
      when :warning then check("project image", :warning, detail)
      else check("project image", :failed, detail.lines.first.strip, fix_for(detail))
      end
    end

    # The image starts as the agents run it, and has the language versions the project pins and
    # the program the agents run.
    def container_check
      found = probe(services: false)
      return false unless found

      versions = %w[ruby node].filter_map { |tool| found[tool].to_s.empty? ? nil : "#{tool} #{found[tool]}" }
      check("container", :ok, versions.any? ? versions.join(", ") : "starts")
      versions_check(found) && agent_check(found)
    end

    def versions_check(found)
      pins = Platform.pinned_runtimes(@directory)
      return true if pins.empty?

      wrong = Platform.version_mismatches(pins, found)
      return check("versions", :ok, pins.map { |tool, version| "#{tool} #{version}" }.join(", ") + " as pinned") if wrong.empty?

      devcontainer = repo[:devcontainer] && JSON.parse(repo[:devcontainer])
      fix = if devcontainer&.dig("tag")
              "make #{devcontainer['path']} use the pinned version (or change the pin), commit it, and run again"
            else
              "commit a .devcontainer/devcontainer.json whose image has it (for Ruby, " \
                "`\"image\": \"ghcr.io/rails/devcontainer/images/ruby:#{pins['ruby'] || 'X.Y.Z'}\"`), or set `sandbox: none` " \
                "for this project under `projects:` in #{Config.locate} to build with this machine's tools"
            end
      check("versions", :failed, "the project pins #{wrong.join(' and ')}", fix)
    end

    def agent_check(found)
      adapter = @env.agent("planner", project: repo).adapter.name
      cli = AGENT_CLIS[adapter]
      return true if cli.nil? || Array(found["cli"]).include?(cli)

      check("agent", :failed, "the image has no `#{cli}`, which the #{adapter} agent runs",
            "add it to the project's image (Runeforge's layer installs Claude Code and ruby_llm when the image has npm and gem)")
    end

    def services_check
      services = Array(repo[:devcontainer] && JSON.parse(repo[:devcontainer])["services"])
      return true if services.empty?
      return false unless probe(services: true)

      check("services", :ok, "#{services.map { |s| s['name'] }.join(', ')} start and answer")
    end

    # Runs PROBE in the sandbox; nil (with the failure recorded) when it can't.
    def probe(services:)
      name = services ? "services" : "container"
      run = Dir.mktmpdir("runeforge-doctor") do |dir|
        @env.new_sandbox(image: repo[:image], project: repo, services:).run(workdir: dir, script: PROBE)
      end
      unless run.success?
        check(name, :failed, "a container from #{repo[:image] || @env.config.dig('sandbox', 'image')} exited #{run.exit_code}: " \
                             "#{run.stderr.strip.lines.last(2).join(' ').strip[0, 300]}", fix_for(run.stderr))
        return nil
      end

      run.stdout.lines(chomp: true).each_with_object({}) do |line, found|
        key, value = line.split("=", 2)
        key == "cli" ? (found["cli"] ||= []) << value : found[key] = value
      end
    rescue Sandbox::Unavailable => e
      check(name, :failed, e.message, fix_for(e.message))
      nil
    end

    # Without a sandbox the project's own tools on this machine are what run.
    def host_checks
      pins = Platform.pinned_runtimes(@directory)
      return if pins.empty?

      run = Sandbox::Local.new(timeout: 60).run(workdir: @directory, script: PROBE)
      found = run.stdout.lines(chomp: true).to_h { |line| line.split("=", 2) }
      wrong = Platform.version_mismatches(pins, found)
      return check("versions", :ok, pins.map { |tool, version| "#{tool} #{version} as pinned" }.join(", ")) if wrong.empty?

      check("versions", :failed, "the project pins #{wrong.join(' and ')} on this machine",
            "install the pinned versions (e.g. with mise, rbenv or nvm) so they're used in #{@directory}")
    end

    # Only when an embedding model is set: it's an extra, so a model that doesn't answer is a
    # warning (the code index then searches by anchors and words), never a reason not to build.
    def embeddings_check
      embedder = @env.embedder
      return unless embedder.enabled?

      ok, detail = embedder.check
      return check("embeddings", :ok, detail) if ok

      fix = embedder.ollama? ? "start Ollama (`ollama serve`) and run `ollama pull #{embedder.model}`" : "check memory.embedding_* in #{Config.locate}"
      check("embeddings", :warning, "#{detail} The code map will search by anchors and words.", fix)
    end

    def credentials_check
      @env.check_agent_credentials!(project: repo)
      check("credentials", :ok, "set for #{@env.agent('planner', project: repo).label}")
    rescue Error => e
      check("credentials", :failed, e.message.lines.first.strip, e.message.lines.drop(1).map(&:strip).reject(&:empty?).join("; "))
    end

    # Finished work is merged into the base branch of this checkout. Changes not committed there
    # would refuse that merge, but only after the work is done.
    def checkout_check
      work = repo[:url].to_s
      return unless File.directory?(work)

      branch = repo[:base_branch]
      current = Git.run("symbolic-ref", "--quiet", "--short", "HEAD", dir: work, allow_failure: true)&.strip
      return check("checkout", :ok, "work is merged into #{branch}") unless current == branch

      changed = Git.run("status", "--porcelain", "--untracked-files=no", dir: work).lines.map { |line| line[3..].strip }
      return check("checkout", :ok, "#{branch} is clean; work is merged into it") if changed.empty?

      shown = changed.first(5).join(", ") + (changed.size > 5 ? ", ..." : "")
      check("checkout", :failed, "#{branch} has uncommitted changes (#{shown}), so finished work couldn't be merged into it",
            "commit or stash them (`git -C #{work} stash`), then run again")
    end

    def fix_for(text)
      case text.to_s
      when /no space left on device|input\/output error/i
        "#{runtime} ran out of disk space or its storage failed: free space on this machine (`df -h`), " \
          "run `#{runtime} system prune`, restart #{runtime == 'docker' ? 'Docker Desktop' : runtime}, then run again"
      when /isn't installed|isn't on PATH/ then "install #{runtime} and make sure it runs in this shell"
      when /Cannot connect|daemon is not running|isn't running|is it running/i then "start #{runtime}, then run again"
      when /service .* (?:didn't start|wasn't ready)/
        "check that the service's image runs (`#{runtime} run --rm IMAGE`) and that its settings in the compose file are right"
      when /didn't build/ then "see the build log named above, fix the devcontainer files or #{runtime}, commit, and run again"
      end
    end
  end
end
