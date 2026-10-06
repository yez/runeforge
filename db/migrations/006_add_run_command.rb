# frozen_string_literal: true

# How to run a repository's project (`run_command` in .runeforge/project.json; see
# docs/run-conventions.md), and whether the reviewer requires the README to say it. That's only
# when Runeforge defined the command itself; a project's own launch method is left alone.
Sequel.migration do
  change do
    alter_table(:runeforge_repos) do
      add_column :run_command, String, text: true
      add_column :run_docs_required, TrueClass, null: false, default: false
    end
  end
end
