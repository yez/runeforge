# frozen_string_literal: true

# The last platform check for a repo (see Runeforge::Platform): whether its project can be
# built where Runeforge builds it, and why not. Shown by `runeforge status -d DIR`.
Sequel.migration do
  change do
    alter_table(:runeforge_repos) do
      add_column :platform, String, size: 20
      add_column :platform_status, String, size: 20
      add_column :platform_note, String, text: true
      add_column :platform_checked_at, DateTime
    end
  end
end
