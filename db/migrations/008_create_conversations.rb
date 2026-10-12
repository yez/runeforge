# frozen_string_literal: true

# One agent conversation per planned step (see Runeforge::Conversations): the planner starts it
# and the coder's attempts continue it, so they don't each learn the project again.
Sequel.migration do
  up do
    create_table(:runeforge_conversations) do
      primary_key :id, type: :Bignum
      String :task_id, size: 100, null: false
      String :repo, size: 100
      String :adapter, size: 20, null: false     # claude_code keeps a session; ruby_llm keeps messages
      String :session_id, size: 100              # Claude Code's session, resumed by the next run
      Float :reported_cost_usd, default: 0.0     # the session's cost so far, as Claude Code reports it
      DateTime :created_at
      DateTime :updated_at

      index :task_id
    end

    # The ruby_llm agent's transcript: each message as RubyLLM::Message#to_h, in order.
    create_table(:runeforge_conversation_messages) do
      primary_key :id, type: :Bignum
      foreign_key :conversation_id, :runeforge_conversations, type: :Bignum, null: false, on_delete: :cascade
      Integer :seq, null: false
      String :role, size: 20, null: false
      String :payload, text: true, null: false
      Bignum :message_id                         # the mailbox message whose run added it
      DateTime :created_at

      index %i[conversation_id seq], unique: true
    end
  end

  down do
    drop_table(:runeforge_conversation_messages)
    drop_table(:runeforge_conversations)
  end
end
