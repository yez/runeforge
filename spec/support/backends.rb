# frozen_string_literal: true

# Specs that touch the database run once per backend. SQLite always runs; PostgreSQL runs when
# RUNEFORGE_TEST_PG_URL is set, e.g. postgres://localhost/runeforge_test.
module Backends
  PG_URL = ENV.fetch("RUNEFORGE_TEST_PG_URL", nil)
  TABLES = %i[runeforge_events runeforge_workers runeforge_messages runeforge_tasks runeforge_repos runeforge_schema_info].freeze

  def self.kinds = PG_URL ? %w[sqlite postgres] : %w[sqlite]

  def self.connect(kind, dir)
    db = Runeforge::DB.connect(kind == "sqlite" ? "sqlite://#{File.join(dir, 'test.db')}" : PG_URL)
    db.drop_table?(*TABLES) if kind == "postgres"
    Runeforge::DB.migrate!(db)
    db
  end

  module GroupMethods
    def on_each_backend(&block)
      Backends.kinds.each do |kind|
        context "on #{kind}" do
          let(:backend) { kind }
          class_exec(&block)
        end
      end
    end
  end
end
