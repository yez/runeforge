# frozen_string_literal: true

module Runeforge
  module DB
    MIGRATIONS = File.expand_path("../../db/migrations", __dir__)
    # Own version table, so embedding in an app never collides with its migrations.
    SCHEMA_TABLE = :runeforge_schema_info

    def self.connect(url)
      opts = url.start_with?("sqlite") ? { timeout: 10_000 } : {}
      sqlite_path = url[%r{\Asqlite://(/.+)\z}, 1]
      FileUtils.mkdir_p(File.dirname(sqlite_path)) if sqlite_path
      db = Sequel.connect(url, **opts)
      db.timezone = :utc
      db.run("PRAGMA journal_mode=WAL") if db.database_type == :sqlite
      db
    end

    def self.migrate!(db)
      Sequel.extension(:migration)
      Sequel::Migrator.run(db, MIGRATIONS, table: SCHEMA_TABLE)
    end

    def self.migrated?(db)
      Sequel.extension(:migration)
      Sequel::Migrator.is_current?(db, MIGRATIONS, table: SCHEMA_TABLE)
    end

    def self.postgres?(db) = db.database_type == :postgres
  end
end
