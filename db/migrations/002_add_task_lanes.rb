# frozen_string_literal: true

# A lane keeps a foreground run's messages away from background workers: its recipients are
# "<lane>/<role>" instead of "<role>".
Sequel.migration do
  change do
    alter_table(:runeforge_tasks) do
      add_column :lane, String, size: 40
    end
  end
end
