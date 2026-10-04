# frozen_string_literal: true

module Runeforge
  module Sandbox
    Result = Data.define(:exit_code, :stdout, :stderr, :timed_out) do
      def success? = exit_code.zero? && !timed_out
    end

    def self.build(config, image:)
      case config.fetch("mode")
      when "docker", "podman"
        Container.new(
          runtime: config.fetch("mode"), image: image || config.fetch("image"),
          network: config.fetch("network"), cpus: config.fetch("cpus"), memory: config.fetch("memory"),
          pids: config.fetch("pids"), timeout: config.fetch("timeout_seconds")
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

      def initialize(runtime:, image:, network:, cpus:, memory:, pids:, timeout:,
                     user: "#{Process.uid}:#{Process.gid}")
        @runtime = runtime
        @image = image
        @network = network
        @cpus = cpus
        @memory = memory
        @pids = pids
        @timeout = timeout
        @user = user
      end

      def run(workdir:, script:, env: {}, on_output: nil)
        @id = "runeforge-#{SecureRandom.hex(6)}"
        Runner.run(argv(workdir, script, env.keys), env:, timeout: @timeout, on_timeout: -> { kill }, on_output:)
      ensure
        @id = nil
      end

      def kill
        name = @id
        system(@runtime, "kill", name, out: File::NULL, err: File::NULL) if name
      end

      def argv(workdir, script, env_names)
        args = [
          @runtime, "run", "--rm", "--name", @id,
          "--network", @network,
          "--read-only", "--tmpfs", "/tmp:rw,exec,size=1g",
          "--cpus", @cpus.to_s, "--memory", @memory.to_s, "--pids-limit", @pids.to_s,
          "--security-opt", "no-new-privileges", "--cap-drop", "ALL",
          "--user", @user,
          "-e", "HOME=/tmp/home",
          "-v", "#{workdir}:/workspace", "-w", "/workspace"
        ]
        # Pass variables by name so their values never appear in the process list.
        env_names.each { |name| args.push("-e", name) }
        args.push(@image, "sh", "-c", script)
      end
    end

    # Runs on the host with a scrubbed environment. For trusted local use only.
    class Local
      PASSTHROUGH = %w[PATH HOME USER LANG LC_ALL TERM SHELL TMPDIR].freeze

      def initialize(timeout:)
        @timeout = timeout
      end

      def id = @pid && "pid-#{@pid}"

      def run(workdir:, script:, env: {}, on_output: nil)
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
