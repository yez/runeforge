# frozen_string_literal: true

# The commit on the base branch that took in a task's work, when Runeforge merged it.
Sequel.migration do
  change do
    alter_table(:runeforge_tasks) do
      add_column :merged_sha, String, size: 64
    end
  end
end
