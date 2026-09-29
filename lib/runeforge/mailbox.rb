# frozen_string_literal: true

module Runeforge
  # The messages table used as a queue. Claims take a lease; a worker that stops heartbeating
  # loses its lease and the reaper hands the message to someone else.
  class Mailbox
    class LeaseLost < Error; end

    attr_reader :db, :worker_id, :lease_seconds, :max_deliveries

    def initialize(db, worker_id:, lease_seconds: 300, max_deliveries: 3)
      @db = db
      @worker_id = worker_id
      @lease_seconds = lease_seconds
      @max_deliveries = max_deliveries
    end

    def messages = db[:runeforge_messages]

    # Returns the new message id, or nil when the dedupe key was already used.
    def post(task_id:, type:, recipient:, payload: {}, sender: worker_id, in_reply_to: nil, commit_sha: nil, dedupe_key: nil)
      db.transaction(savepoint: true) do
        messages.insert(
          task_id: task_id.to_s, type: type.to_s, recipient: recipient.to_s, sender: sender.to_s,
          in_reply_to:, commit_sha:, payload: JSON.generate(payload), dedupe_key:,
          state: "pending", delivery_count: 0, created_at: Runeforge.now
        )
      end
    rescue Sequel::UniqueConstraintViolation
      nil
    end

    def claim(recipients)
      recipients = Array(recipients).map(&:to_s)
      transaction do
        ds = messages.where(recipient: recipients, state: "pending").order(:id).limit(1)
        ds = ds.for_update.skip_locked if DB.postgres?(db)
        row = ds.first
        next nil unless row

        updated = messages.where(id: row[:id], state: "pending").update(
          state: "claimed", claimed_by: worker_id,
          lease_expires_at: Runeforge.now + lease_seconds,
          delivery_count: Sequel[:delivery_count] + 1
        )
        next nil if updated.zero?

        find(row[:id])
      end
    end

    # Marks a claimed message done and runs the block in the same transaction.
    # Raises LeaseLost if the claim was taken back in the meantime.
    def settle(msg)
      transaction do
        owned = messages.where(id: msg.id, claimed_by: worker_id, state: "claimed")
                        .update(state: "done", lease_expires_at: nil)
        raise LeaseLost, "message #{msg.id} was reclaimed" if owned.zero?

        yield if block_given?
      end
    end

    # Completes the claim, records the result for the supervisor and updates the task, atomically.
    def complete(msg, result_type:, payload: {}, commit_sha: nil, task_updates: {})
      settle(msg) do
        post(
          task_id: msg.task_id, type: result_type, payload:,
          recipient: Runeforge.recipient(Runeforge.lane_of(msg.recipient), "supervisor"),
          sender: "#{Runeforge.role_of(msg.recipient)}:#{worker_id}", in_reply_to: msg.id, commit_sha:,
          dedupe_key: "#{msg.task_id}:#{result_type}:#{msg.id}"
        )
        db[:runeforge_tasks].where(id: msg.task_id).update(task_updates.merge(updated_at: Runeforge.now))
      end
    end

    def heartbeat(msg)
      messages.where(id: msg.id, claimed_by: worker_id, state: "claimed")
              .update(lease_expires_at: Runeforge.now + lease_seconds)
              .positive?
    end

    # Gives a message back after a handler error. Dead-letters it after max_deliveries.
    def release(msg, error:)
      transaction do
        row = messages.where(id: msg.id, claimed_by: worker_id, state: "claimed").first
        next false unless row

        requeue_or_bury(row, error)
        true
      end
    end

    # Requeues claimed messages whose lease expired. Returns the ids it touched.
    def reap
      transaction do
        expired = messages.where(state: "claimed").where(Sequel[:lease_expires_at] < Runeforge.now).all
        expired.each { |row| requeue_or_bury(row, "lease expired (held by #{row[:claimed_by]})") }
        expired.map { |row| row[:id] }
      end
    end

    def find(id)
      row = messages.where(id:).first
      row && Message.from_row(row)
    end

    def transaction(&)
      DB.postgres?(db) ? db.transaction(&) : db.transaction(mode: :immediate, &)
    end

    private

    def requeue_or_bury(row, error)
      scope = messages.where(id: row[:id])
      if row[:delivery_count] >= max_deliveries
        scope.update(state: "dead", lease_expires_at: nil, last_error: error)
        db[:runeforge_tasks].where(id: row[:task_id]).exclude(status: TERMINAL_STATUSES).update(
          status: "blocked", updated_at: Runeforge.now,
          error: "message #{row[:id]} (#{row[:type]}) failed #{row[:delivery_count]} times: #{error}"
        )
      else
        scope.update(state: "pending", claimed_by: nil, lease_expires_at: nil, last_error: error)
      end
    end
  end
end
