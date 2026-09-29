# frozen_string_literal: true

Sequel.migration do
  up do
    json_type = database_type == :postgres ? :jsonb : :text

    create_table(:runeforge_repos) do
      String :name, primary_key: true, size: 100
      String :url, text: true, null: false
      String :base_branch, size: 255, null: false, default: "main"
      String :image, text: true
      String :test_command, text: true, null: false
      String :setup_command, text: true
      DateTime :created_at
    end

    create_table(:runeforge_tasks) do
      String :id, primary_key: true, size: 100
      String :workflow, size: 100, null: false
      String :status, size: 30, null: false
      String :repo, size: 100, null: false
      String :title, text: true
      String :ticket, size: 100
      String :base_sha, size: 64, null: false
      String :branch, size: 255, null: false
      String :head_sha, size: 64
      String :spec, text: true
      String :locked_paths, text: true # JSON: path => git object id at plan time
      Integer :attempts, null: false, default: 0
      Integer :max_attempts, null: false, default: 5
      Bignum :tokens_used, null: false, default: 0
      Bignum :token_budget
      Integer :cost_cents, null: false, default: 0
      String :external_pr_url, text: true
      String :error, text: true
      DateTime :deadline_at
      DateTime :created_at
      DateTime :updated_at

      index :status
    end

    create_table(:runeforge_messages) do
      primary_key :id, type: :Bignum
      String :task_id, size: 100, null: false
      String :type, size: 100, null: false
      String :recipient, size: 50, null: false
      String :sender, size: 255, null: false
      Bignum :in_reply_to
      String :commit_sha, size: 64
      column :payload, json_type, null: false
      String :dedupe_key, size: 255, unique: true
      String :state, size: 20, null: false, default: "pending" # pending|claimed|done|dead|cancelled
      String :claimed_by, size: 255
      DateTime :lease_expires_at
      Integer :delivery_count, null: false, default: 0
      String :last_error, text: true
      DateTime :created_at

      index %i[recipient state id]
      index %i[task_id id]
    end

    create_table(:runeforge_workers) do
      String :id, primary_key: true, size: 255
      String :roles, size: 255, null: false
      Bignum :current_message_id
      String :sandbox_id, size: 255
      DateTime :heartbeat_at, null: false
      DateTime :started_at
    end
  end

  down do
    drop_table(:runeforge_workers, :runeforge_messages, :runeforge_tasks, :runeforge_repos)
  end
end
