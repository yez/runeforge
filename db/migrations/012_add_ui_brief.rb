# frozen_string_literal: true

# What a step changes in the user interface, as the planner described it (.runeforge/ui.md): the
# screens to open, the states to check and what they should match. A task with one gets a UX
# review in a real browser before it's merged (see Roles::UxReviewer).
Sequel.migration do
  change do
    alter_table(:runeforge_tasks) do
      add_column :ui_brief, String, text: true
    end
  end
end
