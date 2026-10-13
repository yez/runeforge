# frozen_string_literal: true

require "socket"

module Runeforge
  # Claims commands for its roles, runs the role handler and records the result. A heartbeat
  # thread keeps the lease alive and kills the sandbox if the lease or the task goes away.
  class Worker
    attr_reader :env, :roles, :id, :mailbox, :lane, :repo

    # With a lane, works only on that foreground run's messages; with a repo, only on that
    # repository's background tasks (`runeforge resume` building its inbox).
    def initialize(env, roles:, id: nil, lane: nil, repo: nil)
      @env = env
      @roles = Array(roles).map(&:to_s)
      unknown = @roles - Roles.names
      raise Error, "unknown roles: #{unknown.join(', ')} (known: #{Roles.names.join(', ')})" if unknown.any?

      @lane = lane
      @repo = repo
      @id = id || "#{@roles.join('+')}@#{Socket.gethostname}:#{Process.pid}"
      @mailbox = env.mailbox(@id)
    end

    def run(stop: -> { false })
      announce
      until stop.call
        next if work_once

        beat
        sleep(env.config["poll_seconds"])
      end
    ensure
      unregister
    end

    def unregister
      workers.where(id:).delete
      Events.emit(env.db, "worker.stopped", actor: id, roles:)
      @announced = false
    end

    # Kills whatever sandbox is running right now (used for Ctrl-C in the foreground). release:
    # the killed run isn't a result; its message goes back to the queue to run again.
    def interrupt(release: false)
      @interrupted = release
      @sandbox&.kill
    end

    # Why the sandbox couldn't run the last message (Sandbox::Unavailable), until one runs. A
    # foreground run stops on it; a background worker waits UNAVAILABLE_PAUSE before trying again.
    attr_reader :unavailable

    UNAVAILABLE_PAUSE = 60

    # Handles at most one message. Returns true if it did any work.
    def work_once
      announce
      return false if @unavailable_at && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @unavailable_at < UNAVAILABLE_PAUSE

      msg = mailbox.claim(roles.map { |role| Runeforge.recipient(lane, role) }, task_ids: repo && env.tasks.ids_in(repo))
      return false unless msg

      process(msg)
      true
    end

    private

    def process(msg)
      project = prepare_project(project_for(msg), msg)
      sandbox = @sandbox = env.new_sandbox(image: project&.dig(:image), project:)
      beat(msg)
      heartbeat = start_heartbeat(msg, sandbox)
      role = Runeforge.role_of(msg.recipient)
      outcome = (env.dry_run? ? DryRun.fetch(role) : Roles.fetch(role)).call(env, msg, sandbox)
      return mailbox.release(msg, error: "interrupted from the terminal", counted: false) if @interrupted

      mailbox.complete(msg, **outcome)
      @unavailable = @unavailable_at = nil
    rescue Sandbox::Unavailable => e
      # Not the agent's doing: the message waits, without using a delivery, until the sandbox works.
      mailbox.release(msg, error: "the sandbox is unavailable: #{e.message}", counted: false)
      @unavailable = e.message
      @unavailable_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) if lane.nil? && repo.nil?
      warn "runeforge: #{e.message}; trying again in #{UNAVAILABLE_PAUSE}s" if @unavailable_at
    rescue Mailbox::LeaseLost
      # Reclaimed or cancelled while we worked; someone else owns the message now.
      nil
    rescue StandardError => e
      mailbox.release(msg, error: "#{e.class}: #{e.message}")
    ensure
      @sandbox = nil
      @interrupted = false
      heartbeat&.kill
      beat
    end

    # The message's repo: its image, and its per-project sandbox mode.
    def project_for(msg)
      task = env.tasks.find(msg.task_id)
      task && env.repos.fetch(task[:repo])
    rescue Error
      nil
    end

    PREPARE_EVERY = 300

    # A background worker (`runeforge up`) builds the project's devcontainer image before its
    # first run there, and checks it again every PREPARE_EVERY seconds; foreground runs already
    # did (Doctor). Returns the repo row as it is now.
    def prepare_project(project, msg)
      return project unless project && lane.nil? && repo.nil?

      @prepared ||= {}
      return project if @prepared[project[:name]] && Runeforge.now - @prepared[project[:name]] < PREPARE_EVERY

      # Building an image can outlast the lease; keep it while it builds.
      keepalive = Thread.new do
        loop do
          sleep(env.config["heartbeat_seconds"])
          mailbox.heartbeat(msg)
        end
      rescue StandardError
        nil
      end
      status, detail = Devcontainer.ensure_image(env, project[:name])
      warn "runeforge: #{project[:name]}: #{detail}" if %i[warning failed].include?(status)
      @prepared[project[:name]] = Runeforge.now
      env.repos.fetch(project[:name])
    rescue Error => e
      warn "runeforge: #{project[:name]}: #{e.message}"
      project
    ensure
      keepalive&.kill
    end

    def start_heartbeat(msg, sandbox)
      Thread.new do
        loop do
          sleep(env.config["heartbeat_seconds"])
          next if mailbox.heartbeat(msg) && beat(msg, sandbox)

          sandbox.kill
          break
        end
      rescue StandardError
        nil
      end
    end

    # Registers and records worker.started once, before the first claim, however the worker is
    # driven (#run in the background, #work_once in a foreground build), so live views know it.
    def announce
      return if @announced

      register
      Events.emit(env.db, "worker.started", actor: id, roles:)
      @announced = true
    end

    def register
      workers.insert_conflict(target: :id, update: { heartbeat_at: Runeforge.now })
             .insert(id:, roles: roles.join(","), heartbeat_at: Runeforge.now, started_at: Runeforge.now)
    end

    # Updates this worker's row and returns false if the message's task was stopped.
    def beat(msg = nil, sandbox = nil)
      register unless workers.where(id:).update(
        heartbeat_at: Runeforge.now, current_message_id: msg&.id, sandbox_id: sandbox&.id
      ).positive?
      return true unless msg

      !TERMINAL_STATUSES.include?(env.tasks.find(msg.task_id)&.dig(:status))
    end

    def workers = env.db[:runeforge_workers]
  end
end
