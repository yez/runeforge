# frozen_string_literal: true

# An append-only feed of what happened, for live viewers (the dashboard). Rows are written in
# the same transaction as the change they describe; the id is the stream cursor. The tables
# themselves stay the source of truth, so old events can be pruned.
Sequel.migration do
  up do
    json_type = database_type == :postgres ? :jsonb : :text

    create_table(:runeforge_events) do
      primary_key :id, type: :Bignum
      String :kind, size: 50, null: false
      String :task_id, size: 100
      Bignum :message_id
      String :actor, size: 255
      column :data, json_type, null: false
      DateTime :created_at, null: false

      index %i[task_id id]
      index :created_at
    end
  end

  down do
    drop_table(:runeforge_events)
  end
end
