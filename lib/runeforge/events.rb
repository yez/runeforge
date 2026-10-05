# frozen_string_literal: true

module Runeforge
  # Writes and reads the runeforge_events feed. Callers emit inside the transaction that makes
  # the change, so an event exists exactly when its change does. On PostgreSQL each emit also
  # sends a NOTIFY (delivered at commit) so listeners don't have to poll.
  module Events
    CHANNEL = "runeforge_events"
    STRING_LIMIT = 500
    ARRAY_LIMIT = 50
    # Task columns a viewer needs to draw progress.
    TASK_FIELDS = %i[id status title repo lane attempts max_attempts tokens_used cost_cents head_sha error
                     external_pr_url merged_sha updated_at].freeze

    module_function

    def table(db) = db[:runeforge_events]

    def emit(db, kind, task_id: nil, message_id: nil, actor: nil, **data)
      insert(db, kind, task_id, message_id, actor, clip(data))
    end

    # agent.output: a chunk of a running agent's or test suite's output, unclipped.
    def output(db, msg, text:, actor: nil, stream: "stdout")
      insert(db, "agent.output", msg.task_id, msg.id, actor || msg.claimed_by,
             "role" => Runeforge.role_of(msg.recipient), "stream" => stream, "text" => text)
    end

    def insert(db, kind, task_id, message_id, actor, data)
      id = table(db).insert(kind: kind.to_s, task_id: task_id&.to_s, message_id:, actor: actor&.to_s,
                            data: JSON.generate(data), created_at: Runeforge.now)
      db.notify(CHANNEL) if DB.postgres?(db)
      id
    end

    # message.posted, message.claimed, message.done, ... for a messages row (or Message).
    def message(db, kind, row, actor: nil, **extra)
      row = row.to_h
      emit(db, kind, task_id: row[:task_id], message_id: row[:id], actor: actor || row[:claimed_by],
                     type: row[:type], recipient: row[:recipient], role: Runeforge.role_of(row[:recipient]),
                     sender: row[:sender], in_reply_to: row[:in_reply_to], commit_sha: row[:commit_sha],
                     delivery_count: row[:delivery_count], **extra)
    end

    # task.created / task.updated with the task's current row.
    def task(db, task_id, kind = "task.updated")
      row = db[:runeforge_tasks].where(id: task_id.to_s).first
      emit(db, kind, task_id:, **task_fields(row)) if row
    end

    def task_fields(row) = row.slice(*TASK_FIELDS).transform_values { |value| value.is_a?(Time) ? value.utc.iso8601 : value }

    # Cancels the pending and claimed messages in `scope`, with one event each.
    def cancel_messages(db, scope)
      rows = scope.where(state: %w[pending claimed]).select(:id, :task_id, :type, :recipient, :sender, :claimed_by).all
      return if rows.empty?

      db[:runeforge_messages].where(id: rows.map { |row| row[:id] }).update(state: "cancelled")
      rows.each { |row| message(db, "message.cancelled", row) }
    end

    def since(db, after: 0, task_id: nil, limit: 500)
      ds = table(db).where(Sequel[:id] > after.to_i).order(:id).limit(limit)
      ds = ds.where(task_id: task_id.to_s) if task_id
      ds.all.map { |row| to_h(row) }
    end

    def cursor(db) = table(db).max(:id) || 0

    def prune(db, before:) = table(db).where(Sequel[:created_at] < before).delete

    def to_h(row)
      {
        id: row[:id], kind: row[:kind], task_id: row[:task_id], message_id: row[:message_id], actor: row[:actor],
        at: row[:created_at]&.utc&.iso8601(3), data: Message.parse_payload(row[:data])
      }
    end

    # Keeps events small: payloads can hold whole specs and test logs.
    def clip(value)
      case value
      when String
        text = utf8(value)
        text.length > STRING_LIMIT ? "#{text[0, STRING_LIMIT]}…" : text
      when Array then value.first(ARRAY_LIMIT).map { |item| clip(item) }
      when Hash then value.to_h { |key, item| [key.to_s, clip(item)] }
      when Time then value.utc.iso8601
      else value
      end
    end

    # A payload with every string as valid UTF-8, for storing as JSON (raw bytes only warn in
    # json 2.x and raise from 3.0).
    def to_utf8(value)
      case value
      when String then utf8(value)
      when Array then value.map { |item| to_utf8(item) }
      when Hash then value.to_h { |key, item| [key, to_utf8(item)] }
      else value
      end
    end

    # Strings from agents can arrive as raw bytes; read them as UTF-8, replacing invalid bytes.
    def utf8(text)
      return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?

      text.dup.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
