# frozen_string_literal: true

require "rack"
require_relative "event_hub"

module Runeforge
  module Web
    # Live view of a running Runeforge: a snapshot API plus a Server-Sent Events stream of
    # runeforge_events. Load GET /api/state first, then open GET /api/events?after=<cursor>, so
    # nothing falls between the two. Run it with `runeforge dashboard` (Puma).
    #
    # Each open stream holds a server thread, so serve it from a threaded server. When
    # RUNEFORGE_DASHBOARD_TOKEN is set, /api requires it as ?token= or an X-Runeforge-Token header.
    class DashboardApp
      PAGE = File.expand_path("dashboard/index.html", __dir__)
      SSE_HEADERS = {
        "content-type" => "text/event-stream", "cache-control" => "no-cache", "x-accel-buffering" => "no"
      }.freeze
      TASK_ROUTE = %r{\A/api/tasks/([^/]+)(?:/(cancel|retry))?\z}

      def initialize(env, hub: nil, keepalive_seconds: 15, token: ENV.fetch("RUNEFORGE_DASHBOARD_TOKEN", nil))
        @env = env
        @hub = hub || EventHub.new(env.db).start
        @keepalive = keepalive_seconds
        @token = token
      end

      # Ends open event streams. Call it when the server starts shutting down: a stream never
      # finishes by itself, so a graceful stop would otherwise wait on every open tab.
      def shutdown = @hub.close

      def call(rack_env)
        request = Rack::Request.new(rack_env)
        path = request.path_info
        return page if request.get? && ["", "/", "/index.html"].include?(path)
        return json(404, error: "not found") unless path.start_with?("/api/")
        return json(401, error: "bad token") unless authorized?(request)

        route(request, path)
      rescue Error => e
        json(422, error: e.message)
      end

      private

      def route(request, path)
        if request.get? && path == "/api/state" then json(200, state)
        elsif request.get? && path == "/api/events" then stream(request)
        elsif (match = path.match(TASK_ROUTE))
          id, action = match.captures
          if request.get? && action.nil? then json(200, task_detail(id))
          elsif request.post? && action
            # A custom header can't be sent cross-origin without a preflight we never answer.
            return json(403, error: "missing X-Runeforge-Dashboard header") unless request.get_header("HTTP_X_RUNEFORGE_DASHBOARD")

            json(200, act(id, action, request))
          else json(405, error: "method not allowed")
          end
        else json(404, error: "not found")
        end
      end

      def db = @env.db

      # Read the cursor before the tables: an event that lands in between is sent twice, never lost.
      def state
        cursor = Events.cursor(db)
        tasks = db[:runeforge_tasks].order(Sequel.desc(:updated_at)).limit(50).all
        recent = Events.table(db).order(Sequel.desc(:id)).exclude(kind: %w[agent.output message.heartbeat])
                       .limit(80).all.reverse
        {
          cursor:,
          dry_run: @env.dry_run?,
          roles: ["supervisor", *Roles.names, "operator"],
          tasks: tasks.map { |row| Events.task_fields(row) },
          messages: db[:runeforge_messages].where(state: %w[pending claimed]).order(:id).all.map { |row| message_json(row) },
          workers: db[:runeforge_workers].order(:id).all.map { |row| worker_json(row) },
          events: recent.map { |row| Events.to_h(row) }
        }
      end

      def task_detail(id)
        task = @env.tasks.find!(id)
        { task: Events.task_fields(task).merge(spec: Events.clip(task[:spec].to_s)),
          messages: db[:runeforge_messages].where(task_id: id).order(:id).all.map { |row| message_json(row) } }
      end

      def act(id, action, request)
        body = request.body&.read.to_s
        params = body.empty? ? {} : JSON.parse(body)
        case action
        when "cancel"
          @env.tasks.cancel(id, reason: params.fetch("reason", "cancelled from the dashboard"))
        when "retry"
          @env.tasks.retry_from(id, message_id: params.fetch("from_message"), add_attempts: params.fetch("add_attempts", 0),
                                    mailbox: @env.mailbox("human:dashboard"))
        end
        { ok: true }
      rescue JSON::ParserError, KeyError => e
        raise Error, "bad request: #{e.message}"
      end

      def stream(request)
        after = (request.get_header("HTTP_LAST_EVENT_ID") || request.GET["after"]).to_i
        [200, SSE_HEADERS.dup, EventStream.new(db, @hub, after:, task_id: request.GET["task"], keepalive: @keepalive)]
      end

      def message_json(row)
        msg = Message.from_row(row)
        msg.to_h.except(:payload).merge(
          role: Runeforge.role_of(msg.recipient), payload: Events.clip(msg.payload),
          created_at: msg.created_at&.utc&.iso8601(3), lease_expires_at: msg.lease_expires_at&.utc&.iso8601(3)
        )
      end

      def worker_json(row)
        row.merge(roles: row[:roles].split(","))
           .transform_values { |value| value.is_a?(Time) ? value.utc.iso8601(3) : value }
      end

      def authorized?(request)
        return true if @token.to_s.empty?

        given = request.get_header("HTTP_X_RUNEFORGE_TOKEN") || request.GET["token"]
        given && Rack::Utils.secure_compare(given, @token)
      end

      def page = [200, { "content-type" => "text/html; charset=utf-8", "cache-control" => "no-cache" }, [File.read(PAGE)]]

      def json(status, body)
        [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
      end
    end

    # The body of one SSE response. Puma writes each chunk as it is yielded; a write to a closed
    # connection raises out of `each`, which ends the stream.
    class EventStream
      BATCH = 500

      def initialize(db, hub, after:, task_id: nil, keepalive: 15)
        @db = db
        @hub = hub
        @cursor = after
        @task_id = task_id
        @keepalive = keepalive
      end

      def each
        yield "retry: 2000\n\n"
        until @hub.closed?
          seen = @hub.generation
          events = Events.since(@db, after: @cursor, task_id: @task_id, limit: BATCH)
          events.each { |event| yield frame(event) }
          @cursor = events.last[:id] if events.any?
          next if events.size == BATCH

          moved = @hub.wait(seen, @keepalive)
          yield ": keepalive\n\n" unless moved || @hub.closed?
        end
      end

      def frame(event) = "id: #{event[:id]}\ndata: #{JSON.generate(event)}\n\n"
    end
  end
end
