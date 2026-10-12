# frozen_string_literal: true

# What went wrong in earlier steps (see Runeforge::Memory), shown to the planner of a similar step
# so it doesn't make the same mistake.
Sequel.migration do
  up do
    create_table(:runeforge_lessons) do
      primary_key :id, type: :Bignum
      String :repo, size: 100, null: false
      String :task_id, size: 100
      String :kind, size: 20, null: false      # plan (a rejected plan) | replan (wrong tests) | failed (a failed step)
      String :step, text: true                 # the step's title
      String :text, text: true, null: false    # what went wrong
      String :model, size: 100                 # the embedding model, when there is one
      File :embedding                          # float32 vector, packed
      DateTime :created_at

      index %i[repo id]
    end
  end

  down do
    drop_table(:runeforge_lessons)
  end
end
