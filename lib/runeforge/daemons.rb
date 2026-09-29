# frozen_string_literal: true

require "rbconfig"

module Runeforge
  # Starts and stops the supervisor and workers as background processes, tracked with pid
  # files under <home>/run and logging to <home>/logs/daemons.
  class Daemons
    Status = Data.define(:name, :pid, :state, :log_path)

    EXE = File.expand_path("../../exe/runeforge", __dir__)
    LIB = File.expand_path("..", __dir__)

    def initialize(env, config_path:, database: nil, stop_timeout: 30)
      @env = env
      @config_path = File.expand_path(config_path)
      @database = database
      @stop_timeout = stop_timeout
    end

    # name => CLI arguments, from the `workers` setting.
    def processes
      workers = Array(@env.config["workers"]).map { |roles| roles.delete(" ") }
                                             .to_h { |roles| ["worker-#{roles.tr(',', '-')}", ["worker", "--role", roles]] }
      { "supervisor" => ["supervisor"] }.merge(workers)
    end

    def up = processes.map { |name, args| start(name, args) }

    def down = known_names.map { |name| stop(name) }

    def status
      known_names.map do |name|
        pid = running_pid(name)
        Status.new(name:, pid:, state: pid ? "running" : "stopped", log_path: log_path(name))
      end
    end

    def start(name, args)
      if (pid = running_pid(name))
        return Status.new(name:, pid:, state: "already running", log_path: log_path(name))
      end

      command = [RbConfig.ruby, "-I", LIB, EXE, *args, "--config", @config_path]
      command.push("--database", @database) if @database
      pid = Process.spawn(*command, in: File::NULL, out: [log_path(name), "a"], err: %i[child out], pgroup: true)
      Process.detach(pid)
      File.write(pid_path(name), pid.to_s)
      Status.new(name:, pid:, state: "started", log_path: log_path(name))
    end

    # TERM lets a worker finish its current job; after stop_timeout it is killed and its
    # lease expires, so the message is retried elsewhere.
    def stop(name)
      pid = running_pid(name)
      if pid
        Process.kill("TERM", pid)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @stop_timeout
        sleep 0.2 while alive?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        Process.kill("KILL", -pid) if alive?(pid)
      end
      FileUtils.rm_f(pid_path(name))
      Status.new(name:, pid:, state: pid ? "stopped" : "not running", log_path: log_path(name))
    rescue Errno::ESRCH
      FileUtils.rm_f(pid_path(name))
      Status.new(name:, pid:, state: "stopped", log_path: log_path(name))
    end

    def running_pid(name)
      pid = File.read(pid_path(name)).to_i if File.exist?(pid_path(name))
      return pid if pid&.positive? && alive?(pid) && runeforge_process?(pid, name)

      FileUtils.rm_f(pid_path(name))
      nil
    end

    def log_path(name) = File.join(dir("logs", "daemons"), "#{name}.log")

    private

    def known_names
      (processes.keys + Dir[File.join(dir("run"), "*.pid")].map { |path| File.basename(path, ".pid") }).uniq
    end

    def pid_path(name) = File.join(dir("run"), "#{name}.pid")

    def dir(*parts) = File.join(@env.home, *parts).tap { |path| FileUtils.mkdir_p(path) }

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # Guards against a stale pid file whose pid now belongs to something else: the process must
    # be a runeforge executable running this daemon's command with this config. The executable's
    # location is deliberately not compared, so a checkout and an installed gem can manage the
    # same daemons.
    def runeforge_process?(pid, name)
      out, status = Open3.capture2("ps", "-p", pid.to_s, "-o", "command=")
      return false unless status.success?

      args = processes.fetch(name, [])
      out.match?(%r{/runeforge\s}) && out.include?(" #{args.join(' ')} ") && out.include?("--config #{@config_path}")
    end
  end
end
