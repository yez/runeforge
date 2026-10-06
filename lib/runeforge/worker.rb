# frozen_string_literal: true

require "socket"

module Runeforge
  # Claims commands for its roles, runs the role handler and records the result. A heartbeat
  # thread keeps the lease alive and kills the sandbox if the lease or the task goes away.
  class Worker
    attr_reader :env, :roles, :id, :mailbox, :lane

    # With a lane, works only on that foreground run's messages.
    def initialize(env, roles:, id: nil, lane: nil)
      @env = env
      @roles = Array(roles).map(&:to_s)
      unknown = @roles - Roles.names
      raise Error, "unknown roles: #{unknown.join(', ')} (known: #{Roles.names.join(', ')})" if unknown.any?

      @lane = lane
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

    # Kills whatever sandbox is running right now (used for Ctrl-C in the foreground).
    def interrupt = @sandbox&.kill

    # Handles at most one message. Returns true if it did any work.
    def work_once
      announce
      msg = mailbox.claim(roles.map { |role| Runeforge.recipient(lane, role) })
      return false unless msg

      process(msg)
      true
    end

    private

    def process(msg)
      project = project_for(msg)
      sandbox = @sandbox = env.new_sandbox(image: project&.dig(:image), project:)
      beat(msg)
      heartbeat = start_heartbeat(msg, sandbox)
      role = Runeforge.role_of(msg.recipient)
      outcome = (env.dry_run? ? DryRun.fetch(role) : Roles.fetch(role)).call(env, msg, sandbox)
      mailbox.complete(msg, **outcome)
    rescue Mailbox::LeaseLost
      # Reclaimed or cancelled while we worked; someone else owns the message now.
      nil
    rescue StandardError => e
      mailbox.release(msg, error: "#{e.class}: #{e.message}")
    ensure
      @sandbox = nil
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
