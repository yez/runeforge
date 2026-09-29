# frozen_string_literal: true

module Runeforge
  Message = Data.define(
    :id, :task_id, :type, :recipient, :sender, :in_reply_to, :commit_sha, :payload,
    :state, :claimed_by, :lease_expires_at, :delivery_count, :last_error, :created_at
  ) do
    def self.from_row(row)
      new(**row.slice(*members), payload: parse_payload(row[:payload]))
    end

    # jsonb comes back as a String without Sequel's pg_json extension, or as a Hash-like with it.
    def self.parse_payload(raw)
      raw.is_a?(String) ? JSON.parse(raw) : JSON.parse(JSON.generate(raw))
    end
  end
end
