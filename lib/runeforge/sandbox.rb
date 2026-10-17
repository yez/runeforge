# frozen_string_literal: true

require "digest"

module Runeforge
  module Sandbox
    # The sandbox itself can't run: the container CLI is missing, its daemon is down or broken, a
    # service won't start. Nothing an agent did, so it's never retried as a failed attempt.
    class Unavailable < Error; end

    Result = Data.define(:exit_code, :stdout, :stderr, :timed_out) do
      def success? = exit_code.zero? && !timed_out
    end

    # devcontainer: what Devcontainer.ensure_image stored on the repo (its services, variables and
    # the image's own PATH), or nil.
    # project: the repo's name; with sandbox.dependency_volumes (the default) its runs keep installed
    # dependencies in volumes of their own (see Container#dependency_mounts).
    def self.build(config, image:, devcontainer: nil, project: nil)
      case config.fetch("mode")
      when "docker", "podman"
        Container.new(
          runtime: config.fetch("mode"), image: image || config.fetch("image"),
          network: config.fetch("network"), cpus: config.fetch("cpus"), memory: config.fetch("memory"),
          pids: config.fetch("pids"), timeout: config.fetch("timeout_seconds"),
          services: Array(devcontainer&.dig("services")).map { |hash| Devcontainer::Service.from_h(hash) },
          env: (devcontainer&.dig("defaults") || {}).merge(devcontainer&.dig("env") || {}), name: devcontainer&.dig("main"),
          dependency_cache: config.fetch("dependency_volumes", true) ? project : nil
        )
      when "none"
        Local.new(timeout: config.fetch("timeout_seconds"))
      else
        raise Error, "unknown sandbox mode #{config.fetch('mode').inspect}"
      end
    end

    module Runner
      module_function

      # on_output, if given, receives (chunk, stream) as output arrives, for live viewers.
      def run(argv, env: {}, chdir: nil, timeout: nil, pgroup: false, unsetenv_others: false,
              on_timeout: nil, max_output: 1_000_000, on_output: nil)
        opts = { unsetenv_others:, pgroup: }
        opts[:chdir] = chdir if chdir
        Open3.popen3(env, *argv, **opts) do |stdin, out, err, thread|
          stdin.close
          yield thread.pid if block_given?
          readers = { out => "stdout", err => "stderr" }.map do |io, stream|
            Thread.new { read_tail(io, max_output) { |chunk| on_output&.call(chunk, stream) } }
          end
          timed_out = thread.join(timeout).nil?
          if timed_out
            on_timeout&.call
            terminate(thread.pid, pgroup)
            thread.join
          end
          status = thread.value
          # A leftover background process can hold the pipes open; don't wait on it forever.
          readers.zip([out, err]).each { |reader, io| io.close unless reader.join(5) }
          Result.new(
            exit_code: status.exitstatus || (128 + status.termsig.to_i),
            stdout: readers[0].value, stderr: readers[1].value, timed_out:
          )
        end
      end

      # Keeps the last max_bytes of a stream; the end of a log is the useful part.
      def read_tail(io, max_bytes)
        buffer = +""
        loop do
          chunk = io.readpartial(65_536)
          yield chunk if block_given?
          buffer << chunk
          buffer = buffer.byteslice(-max_bytes, max_bytes) if buffer.bytesize > max_bytes * 2
        end
      rescue EOFError, IOError
        buffer.bytesize > max_bytes ? buffer.byteslice(-max_bytes, max_bytes) : buffer
      end

      def terminate(pid, pgroup)
        target = pgroup ? -pid : pid
        Process.kill("TERM", target)
        sleep 2
        Process.kill("KILL", target)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end

    # One throwaway container per run. Only the workspace is mounted and writable.
    class Container
      attr_reader :id

      # services: started on a private network next to each run, reachable by their names (a
      # devcontainer's postgres, redis, ...); env: variables set in every run; name: the network
      # name of the run's own container (the devcontainer's compose service), for services that
      # connect back to it (a Selenium browser opening the app under test).
      # cpus: a number, or "auto" (or nil) for every CPU the container runtime has.
      # dependency_cache: the project's name, to keep its installed dependencies between runs in
      # container volumes (see #dependency_mounts), or nil to leave them in the workspace.
      def initialize(runtime:, image:, network:, cpus:, memory:, pids:, timeout:,
                     user: "#{Process.uid}:#{Process.gid}", services: [], env: {}, name: nil, ready_seconds: 90,
                     dependency_cache: nil)
        @runtime = runtime
        @image = image
        @network = network
        @cpus = cpus
        @memory = memory
        @pids = pids
        @timeout = timeout
        @user = user
        @services = services
        @env = env
        @name = name
        @ready_seconds = ready_seconds
        @dependency_cache = dependency_cache
      end

      # sessions: a host directory kept as the agent's Claude Code session store, so a later run can
      # resume this one (see Conversations); the container's HOME is otherwise thrown away.
      # Variables the container CLI on this machine needs for itself; set in the container by value,
      # never on the CLI's own process (a container's PATH there hides the `docker` binary).
      HOST_VARIABLES = %w[PATH HOME USER SHELL TMPDIR LANG LC_ALL DOCKER_HOST DOCKER_CONFIG DOCKER_CONTEXT].freeze

      def run(workdir:, script:, env: {}, on_output: nil, sessions: nil)
        @id = "runeforge-#{SecureRandom.hex(6)}"
        values = @env.merge(env.slice(*HOST_VARIABLES))
        secrets = env.except(*HOST_VARIABLES) # by name, after the values, so a caller's setting wins
        start_services if @services.any?
        result = Runner.run(argv(workdir, script, secrets.keys, sessions, values:, volumes: dependency_mounts(workdir)),
                            env: secrets, timeout: @timeout, on_timeout: -> { kill }, on_output:)
        unavailable!(result)
        result
      rescue Errno::ENOENT
        raise Unavailable, "`#{@runtime}` isn't installed or isn't on PATH"
      ensure
        stop_services
        @id = nil
      end

      def kill
        name = @id
        system(@runtime, "kill", name, out: File::NULL, err: File::NULL) if name
      end

      # The private network and service containers of the run in progress.
      def network_name = "#{@id}-net"

      def service_container(service) = "#{@id}-#{service.name}"

      # env_names: passed by name from this process (secrets stay out of the process list);
      # values: set by value (the project's own settings, which aren't secret).
      # volumes: named volume => path under /workspace, mounted over the workspace (see #dependency_mounts).
      def argv(workdir, script, env_names, sessions = nil, values: {}, volumes: {})
        network = @services.any? ? ["--network", network_name, *(@name ? ["--network-alias", @name] : [])] : ["--network", @network]
        args = [
          @runtime, "run", "--rm", "--name", @id,
          *network,
          "--read-only", "--tmpfs", "/tmp:rw,exec,size=1g",
          *cpu_limit, "--memory", @memory.to_s, "--pids-limit", @pids.to_s,
          "--security-opt", "no-new-privileges", "--cap-drop", "ALL",
          "--user", @user,
          "-e", "HOME=/tmp/home",
          "-v", "#{workdir}:/workspace", "-w", "/workspace"
        ]
        args.push("-v", "#{sessions}:/tmp/home/.claude/projects") if sessions
        volumes.each { |volume, path| args.push("-v", "#{volume}:/workspace/#{path}") }
        values.each { |name, value| args.push("-e", "#{name}=#{value}") }
        # Pass variables by name so their values never appear in the process list.
        env_names.each { |name| args.push("-e", name) }
        args.push(@image, "sh", "-c", script)
      end

      # Where a project's package manager installs, by the file that says the project uses it.
      DEPENDENCY_DIRS = { "package.json" => "node_modules" }.freeze
      # Volumes kept per project and folder; older ones are removed when a new one is made.
      DEPENDENCY_VOLUMES_KEPT = 3

      # Installed dependencies live in a volume per project and dependency manifest instead of the
      # workspace. On Docker Desktop and Podman machines the workspace is a folder shared from the
      # host, and reading thousands of small files through it made every test run several times
      # slower (a Node suite: 42s from the shared folder, 14s from a volume); a volume also keeps
      # what one run installed for the next, so installing again is quick. Keyed by the manifest
      # and lock file, so runs that need different packages never install into the same folder.
      # Empty when the project has no such folder, or the volume can't be made (runs then install
      # into the workspace as before).
      def dependency_mounts(workdir)
        return {} unless @dependency_cache

        DEPENDENCY_DIRS.each_with_object({}) do |(manifest, dir), mounts|
          path = File.join(workdir, manifest)
          # A project that commits its dependencies keeps them.
          next unless File.file?(path) && !File.symlink?(path) && !File.exist?(File.join(workdir, dir)) &&
                      !File.symlink?(File.join(workdir, dir))

          volume = dependency_volume(workdir, manifest, dir)
          mounts[volume] = dir if volume
        end
      end

      private

      def cpu_limit = @cpus.nil? || @cpus.to_s == "auto" ? [] : ["--cpus", @cpus.to_s]

      LOCK_FILES = %w[package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lockb].freeze

      def dependency_volume(workdir, manifest, dir)
        digest = Digest::SHA256.new
        [manifest, *LOCK_FILES].each do |name|
          file = File.join(workdir, name)
          digest << name << "\0" << File.binread(file) if File.file?(file) && !File.symlink?(file)
        end
        project = @dependency_cache.to_s.downcase.gsub(/[^a-z0-9_.-]+/, "-")[0, 40]
        volume = "runeforge-deps-#{project}-#{dir.gsub(/[^a-z0-9_.-]+/, '-')}-#{digest.hexdigest[0, 12]}"
        prepare_volume(volume, project, dir) ? volume : nil
      end

      # Makes the volume, owned by the user the runs use, once; then drops this project's oldest.
      def prepare_volume(volume, project, dir)
        quiet = { out: File::NULL, err: File::NULL }
        return true if system(@runtime, "volume", "inspect", volume, **quiet)

        labels = ["--label", "runeforge.project=#{project}", "--label", "runeforge.dependencies=#{dir}"]
        return false unless system(@runtime, "volume", "create", *labels, volume, **quiet)

        unless system(@runtime, "run", "--rm", "--network", "none", "--user", "0", "--entrypoint", "chown",
                      "-v", "#{volume}:/deps", @image, @user, "/deps", **quiet)
          system(@runtime, "volume", "rm", volume, **quiet)
          return false
        end
        prune_volumes(volume, labels)
        true
      rescue Errno::ENOENT
        false
      end

      # Removes this project's other volumes for the folder beyond the newest few. One in use by a
      # run can't be removed, and stays.
      def prune_volumes(keep, labels)
        filters = labels.each_slice(2).flat_map { |_, label| ["--filter", "label=#{label}"] }
        names, = Open3.capture2(@runtime, "volume", "ls", "-q", *filters)
        others = names.split - [keep]
        return if others.size < DEPENDENCY_VOLUMES_KEPT

        created, = Open3.capture2(@runtime, "volume", "inspect", "--format", "{{.CreatedAt}} {{.Name}}", *others)
        stale = created.lines.map(&:split).sort.map(&:last).first(others.size - DEPENDENCY_VOLUMES_KEPT + 1)
        system(@runtime, "volume", "rm", *stale, out: File::NULL, err: File::NULL) if stale.any?
      rescue Errno::ENOENT
        nil
      end

      # Exit 125 is the container CLI failing before the command ran (docker and podman both).
      DAEMON_ERROR = /Error response from daemon|Cannot connect to the (?:Docker|Podman) daemon|error during connect|input\/output error|no space left on device/i

      def unavailable!(result)
        return unless result.exit_code == 125 && result.stderr.match?(DAEMON_ERROR)

        raise Unavailable, "#{@runtime} couldn't start the container: #{result.stderr.strip.lines.last(2).join(' ').strip[0, 400]}"
      end

      # With network: none, the services' network has no way out either.
      def start_services
        quiet = { out: File::NULL, err: File::NULL }
        internal = @network == "none" ? ["--internal"] : []
        created = system(@runtime, "network", "create", *internal, network_name, **quiet)
        raise Unavailable, "`#{@runtime}` isn't installed or isn't on PATH" if created.nil?
        raise Unavailable, "#{@runtime} couldn't create the network #{network_name}; is it running?" unless created

        @services.each do |service|
          env = service.env.flat_map { |name, value| ["-e", "#{name}=#{value}"] }
          started = system(@runtime, "run", "-d", "--rm", "--name", service_container(service), "--network", network_name,
                           "--network-alias", service.name, *cpu_limit, "--memory", @memory.to_s,
                           *shm(service), *env, service.image, **quiet)
          raise Unavailable, "the #{service.name} service (#{service.image}) didn't start" unless started
        end
        @services.each { |service| wait_ready(service) }
      end

      # Docker gives a container 64 MB of /dev/shm, and Chrome crashes its tabs ("page crash") with
      # that little. Browser images get 2 GB, as Selenium's docs say, unless the compose file says.
      BROWSER_IMAGE = /selenium|seleniarm|chrom|browserless|playwright|puppeteer/
      BROWSER_SHM = "2g"

      def shm(service)
        size = service.shm_size || (BROWSER_SHM if service.image.match?(BROWSER_IMAGE))
        size ? ["--shm-size", size] : []
      end

      # The service's own healthcheck, else a check for images known to need one, else none.
      def wait_ready(service)
        check = readiness(service)
        return unless check

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @ready_seconds
        until system(@runtime, "exec", service_container(service), *check, out: File::NULL, err: File::NULL)
          raise Unavailable, "the #{service.name} service (#{service.image}) wasn't ready after #{@ready_seconds}s" if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.5
        end
      end

      def readiness(service)
        test = service.healthcheck
        case test&.first
        when nil, "NONE" then nil
        when "CMD" then return test.drop(1)
        when "CMD-SHELL" then return ["sh", "-c", test.drop(1).join(" ")]
        else return ["sh", "-c", test.join(" ")] # compose's string form
        end

        case service.image
        when /(?:\A|\/)postgres(?:ql)?[:@]|(?:\A|\/)postgres(?:ql)?\z|postgis|pgvector|timescaledb/ then ["pg_isready", "-q"]
        when /(?:\A|\/)redis[:@]|(?:\A|\/)redis\z|valkey/ then ["redis-cli", "ping"]
        when /mysql|mariadb/ then ["sh", "-c", "mysqladmin ping --silent || mariadb-admin ping --silent"]
        end
      end

      def stop_services
        return unless @id && @services.any?

        quiet = { out: File::NULL, err: File::NULL }
        system(@runtime, "rm", "-f", *@services.map { |service| service_container(service) }, **quiet)
        system(@runtime, "network", "rm", network_name, **quiet)
      end
    end

    # Runs on the host with a scrubbed environment. For trusted local use only.
    class Local
      PASSTHROUGH = %w[PATH HOME USER LANG LC_ALL TERM SHELL TMPDIR].freeze

      def initialize(timeout:)
        @timeout = timeout
      end

      def id = @pid && "pid-#{@pid}"

      # sessions is ignored: on this machine Claude Code keeps its sessions in the real HOME.
      def run(workdir:, script:, env: {}, on_output: nil, sessions: nil)
        base = ENV.to_h.slice(*PASSTHROUGH)
        Runner.run(["sh", "-c", script], env: base.merge(env), chdir: workdir, timeout: @timeout,
                                         pgroup: true, unsetenv_others: true, on_output:) { |pid| @pid = pid }
      ensure
        @pid = nil
      end

      def kill
        Process.kill("TERM", -@pid) if @pid
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end
  end
end
