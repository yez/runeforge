# frozen_string_literal: true

# The project's devcontainer as Runeforge uses it (see Runeforge::Devcontainer): JSON with the
# image tag it built, the services started next to each sandbox run and the variables set in it.
Sequel.migration do
  change do
    alter_table(:runeforge_repos) do
      add_column :devcontainer, String, text: true
    end
  end
end
