# frozen_string_literal: true

# The ledger (see Runeforge::Ledger): what each step is for, how steps relate, which code does
# what, which tests pin which requirement, and what agents learned. Written only by Runeforge,
# from plan files and from agents' handoffs after it has checked them against the commit.
Sequel.migration do
  up do
    create_table(:runeforge_items) do
      String :id, primary_key: true, size: 160      # "<plan slug>-p<plan id>.t<n>[.r<m>]"
      String :repo, size: 100, null: false
      Bignum :plan_id                               # runeforge_plans.id
      String :parent_id, size: 160
      String :kind, size: 20, null: false           # plan | ticket | requirement | discovered
      Integer :position, null: false, default: 0    # order within its parent
      String :title, text: true
      String :body, text: true
      String :status, size: 20, null: false, default: "open" # open | in_progress | done | already_built | conflict | blocked | superseded
      String :task_id, size: 100                    # the step task that owns it (its claim)
      String :close_reason, text: true
      String :closed_sha, size: 64
      DateTime :compacted_at
      DateTime :created_at
      DateTime :updated_at

      index %i[repo kind status]
      index :parent_id
      index :task_id
    end

    create_table(:runeforge_links) do
      primary_key :id, type: :Bignum
      String :repo, size: 100, null: false
      String :from_id, size: 160, null: false
      String :to_id, size: 160, null: false
      String :type, size: 30, null: false           # parent-child | blocks | duplicates | overlaps | built-by | extends
                                                    # | supersedes | discovered-from | conflicts-with | related
      String :created_by, size: 255                 # "parser", "inbox", "planner@<task>", ...
      String :note, text: true
      DateTime :created_at

      index %i[from_id type]
      index %i[to_id type]
      index %i[from_id to_id type], unique: true
    end

    # The exact identifiers in an item's text: routes, data-testid values, paths, error strings.
    create_table(:runeforge_anchors) do
      primary_key :id, type: :Bignum
      String :repo, size: 100, null: false
      String :item_id, size: 160, null: false
      String :kind, size: 20, null: false           # route | testid | path | symbol | error | field
      String :value, size: 500, null: false

      index %i[repo kind value]
      index :item_id
    end

    create_table(:runeforge_code_refs) do
      primary_key :id, type: :Bignum
      String :repo, size: 100, null: false
      String :item_id, size: 160
      String :task_id, size: 100
      String :path, text: true, null: false
      String :symbol, size: 255
      Integer :line_start
      Integer :line_end
      String :role, size: 20, null: false           # implements | tests | entrypoint | helper | fixture | config
      String :blob, size: 64                        # the file's git object id when recorded
      TrueClass :stale, null: false, default: false # its file changed since; cleared when confirmed again
      String :note, text: true
      String :source, size: 20, null: false         # handoff | diff
      DateTime :created_at

      index %i[repo stale]
      index :item_id
    end

    create_table(:runeforge_coverage) do
      primary_key :id, type: :Bignum
      String :repo, size: 100, null: false
      String :item_id, size: 160, null: false
      String :test_path, text: true, null: false
      String :test_name, text: true
      TrueClass :locked, null: false, default: true
      String :last_passed_sha, size: 64
      DateTime :created_at

      index :item_id
    end

    create_table(:runeforge_facts) do
      primary_key :id, type: :Bignum
      String :repo, size: 100, null: false
      String :key, size: 100, null: false
      String :kind, size: 20, null: false           # convention | command | layout | gotcha | ux
      String :text, text: true, null: false
      String :paths, text: true                     # JSON array
      String :source_task, size: 100
      String :created_by, size: 50
      Integer :confirmations, null: false, default: 1
      DateTime :last_used_at
      DateTime :created_at
      DateTime :updated_at

      index %i[repo key], unique: true
    end
  end

  down do
    drop_table(:runeforge_facts, :runeforge_coverage, :runeforge_code_refs, :runeforge_anchors, :runeforge_links, :runeforge_items)
  end
end
