# frozen_string_literal: true

require "runeforge"

module Runeforge
  # Optional wrappers for running the supervisor and workers inside an app's job system.
  # Require this file after ActiveJob or Sidekiq is loaded. Each job works for a bounded slice
  # of time and then re-enqueues itself, so it never holds a queue thread forever.
  module Jobs
    def self.run_slice(runner, seconds:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      runner.run(stop: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline })
    end

    def self.supervisor(seconds) = run_slice(Supervisor.new(Runeforge.environment), seconds:)

    def self.worker(roles, seconds) = run_slice(Worker.new(Runeforge.environment, roles:), seconds:)

    if defined?(::ActiveJob::Base)
      class SupervisorJob < ::ActiveJob::Base
        def perform(slice_seconds = 60)
          Jobs.supervisor(slice_seconds)
          self.class.perform_later(slice_seconds)
        end
      end

      class WorkerJob < ::ActiveJob::Base
        def perform(roles, slice_seconds = 300)
          Jobs.worker(roles, slice_seconds)
          self.class.perform_later(roles, slice_seconds)
        end
      end
    end

    if defined?(::Sidekiq::Job)
      class SupervisorSidekiqJob
        include ::Sidekiq::Job

        def perform(slice_seconds = 60)
          Jobs.supervisor(slice_seconds)
          self.class.perform_async(slice_seconds)
        end
      end

      class WorkerSidekiqJob
        include ::Sidekiq::Job

        def perform(roles, slice_seconds = 300)
          Jobs.worker(roles, slice_seconds)
          self.class.perform_async(roles, slice_seconds)
        end
      end
    end
  end
end
