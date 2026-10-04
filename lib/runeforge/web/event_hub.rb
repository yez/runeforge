# frozen_string_literal: true

module Runeforge
  module Web
    # Wakes event streams when new events land. One background thread per process: on PostgreSQL
    # it LISTENs for the NOTIFY sent with each event; on SQLite it polls the newest event id.
    # Streams re-read the table themselves after waking, so a missed wake-up only costs latency.
    class EventHub
      attr_reader :generation

      def initialize(db, poll_seconds: 0.25)
        @db = db
        @poll_seconds = poll_seconds
        @generation = 0
        @mutex = Mutex.new
        @changed = ConditionVariable.new
      end

      def start
        @thread ||= Thread.new { DB.postgres?(@db) ? listen : poll }.tap { |thread| thread.name = "runeforge-event-hub" }
        self
      end

      def stop
        @thread&.kill
        @thread = nil
      end

      # Ends every stream waiting on this hub, so the server can shut down. Safe to call from a
      # signal trap, where a Mutex can't be locked, so the wake-up happens on its own thread.
      def close
        @closed = true
        Thread.new { @mutex.synchronize { @changed.broadcast } }
      end

      def closed? = @closed == true

      # Blocks until the generation moves past `seen`, `timeout` passes or the hub closes.
      # Returns true if it moved.
      def wait(seen, timeout)
        @mutex.synchronize do
          @changed.wait(@mutex, timeout) if @generation == seen && !@closed
          @generation != seen
        end
      end

      def bump
        @mutex.synchronize do
          @generation += 1
          @changed.broadcast
        end
      end

      private

      def poll
        latest = Events.cursor(@db)
        loop do
          sleep @poll_seconds
          current = Events.cursor(@db)
          next if current == latest

          latest = current
          bump
        rescue Sequel::Error
          sleep 1
        end
      end

      def listen
        loop do
          @db.listen(Events::CHANNEL, loop: true) { bump }
        rescue Sequel::Error
          sleep 1
        end
      end
    end
  end
end
