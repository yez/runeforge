# frozen_string_literal: true

module Runeforge
  module Sandbox
    Result = Data.define(:exit_code, :stdout, :stderr, :timed_out) do
      def success? = exit_code.zero? && !timed_out
    end

    # devcontainer: what Devcontainer.ensure_image stored on the repo (its services, variables and
    # the image's own PATH), or nil.
    def self.build(config, image:, devcontainer: nil)
      case config.fetch("mode")
      when "docker", "podman"
        Container.new(
          runtime: config.fetch("mode"), image: image || config.fetch("image"),
          network: config.fetch("network"), cpus: config.fetch("cpus"), memory: config.fetch("memory"),
          pids: config.fetch("pids"), timeout: config.fetch("timeout_seconds"),
          services: Array(devcontainer&.dig("services")).map { |hash| Devcontainer::Service.from_h(hash) },
          env: (devcontainer&.dig("defaults") || {}).merge(devcontainer&.dig("env") || {}), name: devcontainer&.dig("main")
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
      def initialize(runtime:, image:, network:, cpus:, memory:, pids:, timeout:,
                     user: "#{Process.uid}:#{Process.gid}", services: [], env: {}, name: nil, ready_seconds: 90)
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
      end

      # sessions: a host directory kept as the agent's Claude Code session store, so a later run can
      # resume this one (see Conversations); the container's HOME is otherwise thrown away.
      def run(workdir:, script:, env: {}, on_output: nil, sessions: nil)
        @id = "runeforge-#{SecureRandom.hex(6)}"
        env = @env.merge(env)
        start_services if @services.any?
        Runner.run(argv(workdir, script, env.keys, sessions), env:, timeout: @timeout, on_timeout: -> { kill }, on_output:)
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

      def argv(workdir, script, env_names, sessions = nil)
        network = @services.any? ? ["--network", network_name, *(@name ? ["--network-alias", @name] : [])] : ["--network", @network]
        args = [
          @runtime, "run", "--rm", "--name", @id,
          *network,
          "--read-only", "--tmpfs", "/tmp:rw,exec,size=1g",
          "--cpus", @cpus.to_s, "--memory", @memory.to_s, "--pids-limit", @pids.to_s,
          "--security-opt", "no-new-privileges", "--cap-drop", "ALL",
          "--user", @user,
          "-e", "HOME=/tmp/home",
          "-v", "#{workdir}:/workspace", "-w", "/workspace"
        ]
        args.push("-v", "#{sessions}:/tmp/home/.claude/projects") if sessions
        # Pass variables by name so their values never appear in the process list.
        env_names.each { |name| args.push("-e", name) }
        args.push(@image, "sh", "-c", script)
      end

      private

      # With network: none, the services' network has no way out either.
      def start_services
        quiet = { out: File::NULL, err: File::NULL }
        internal = @network == "none" ? ["--internal"] : []
        raise Error, "could not create the network #{network_name}" unless system(@runtime, "network", "create", *internal, network_name, **quiet)

        @services.each do |service|
          env = service.env.flat_map { |name, value| ["-e", "#{name}=#{value}"] }
          started = system(@runtime, "run", "-d", "--rm", "--name", service_container(service), "--network", network_name,
                           "--network-alias", service.name, "--cpus", @cpus.to_s, "--memory", @memory.to_s, *env, service.image, **quiet)
          raise Error, "could not start the #{service.name} service (#{service.image})" unless started
        end
        @services.each { |service| wait_ready(service) }
      end

      # The service's own healthcheck, else a check for images known to need one, else none.
      def wait_ready(service)
        check = readiness(service)
        return unless check

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @ready_seconds
        until system(@runtime, "exec", service_container(service), *check, out: File::NULL, err: File::NULL)
          raise Error, "the #{service.name} service (#{service.image}) wasn't ready after #{@ready_seconds}s" if
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
        when /(?:\A|\/)postgres(?:ql)?[:@]|(?:\A|\/)postgres(?:ql)?\z|postgis/ then ["pg_isready", "-q"]
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
