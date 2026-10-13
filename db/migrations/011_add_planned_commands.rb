# frozen_string_literal: true

# Which of a repo's commands (test_command, setup_command, run_command) a plan recorded, as a JSON
# array. A later plan may replace those; ones set with `runeforge repo add` or `repo set` stay.
Sequel.migration do
  change do
    alter_table(:runeforge_repos) do
      add_column :planned_commands, String, text: true
    end
  end
end
