# frozen_string_literal: true

# One row per version of a plan file in a project's runeforge/inbox/ (see Runeforge::Inbox).
Sequel.migration do
  up do
    create_table(:runeforge_plans) do
      primary_key :id, type: :Bignum
      String :repo, size: 100, null: false
      String :path, text: true, null: false     # e.g. runeforge/inbox/csv-export.md
      String :name, size: 255, null: false      # file name without .md; what after:/replaces: refer to
      String :blob, size: 64, null: false       # git object id of this version
      String :title, text: true
      Integer :arrival, null: false             # first-parent position the plan arrived at (its place)
      Integer :updated, null: false             # first-parent position of its latest change
      # queued | blocked | running | unmerged | done | failed | cancelled | dropped | superseded
      String :status, size: 20, null: false
      String :reason, text: true                # why it's blocked, failed or not merged
      String :after, text: true                 # JSON array of plan names
      String :replaces, text: true              # JSON array of plan names
      Integer :step, null: false, default: 0    # steps finished
      Integer :steps                            # steps in the plan, once started
      String :task_id, size: 100                # the step task running or last run
      String :task_ids, text: true              # JSON array: every step task, in order
      String :inherited, text: true             # JSON array: locked tests carried in from earlier plans
      String :locked, text: true                # JSON array: the tests this plan locked itself
      String :waiting_sha, size: 64             # unmerged work the queue waits on
      DateTime :created_at
      DateTime :updated_at

      index %i[repo status]
      index %i[repo path blob], unique: true
    end
  end

  down do
    drop_table(:runeforge_plans)
  end
end
