# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "pathname"
require "time"

module StructuredDataset
  class Database
    RUNTIME_PATH = "_System/KnowledgeGraph/Runtime/datasets.sqlite3".freeze
    ENGINE_SCHEMA_VERSION = 2

    attr_reader :path

    def initialize(vault_root:, path: nil, clock: nil)
      @path = Pathname.new(path || File.join(File.expand_path(vault_root.to_s), RUNTIME_PATH)).expand_path
      @clock = clock || -> { Time.now }
    end

    def available?
      load_sqlite!
      true
    rescue DependencyError
      false
    end

    def migrate!
      with_connection do |database|
        current = database.get_first_value("PRAGMA user_version").to_i
        raise MigrationError, "dataset database is newer than this engine" if current > ENGINE_SCHEMA_VERSION
        migrate_v1(database) if current < 1
        migrate_v2(database) if current < 2
      end
      ENGINE_SCHEMA_VERSION
    end

    def with_connection
      load_sqlite!
      FileUtils.mkdir_p(path.dirname)
      database = SQLite3::Database.new(path.to_s)
      database.results_as_hash = true
      database.busy_timeout = 5_000
      database.execute("PRAGMA foreign_keys = ON")
      database.execute("PRAGMA journal_mode = WAL") unless path.to_s == ":memory:"
      yield database
    ensure
      database&.close
    end

    def transaction(database)
      database.execute("BEGIN IMMEDIATE")
      value = yield
      database.execute("COMMIT")
      value
    rescue StandardError
      database.execute("ROLLBACK") rescue nil
      raise
    end

    def create_dataset(database, dataset_id:, table_name:, definition:, created_at: timestamp)
      Names.identifier!(table_name, "table name")
      schema_json = JSON.generate(definition.to_h)
      database.execute(
        "INSERT INTO sde_datasets (dataset_id, table_name, schema_version, schema_json, created_at, updated_at) VALUES (?, ?, 1, ?, ?, ?)",
        [dataset_id, table_name, schema_json, created_at, created_at]
      )
      database.execute(
        "INSERT INTO sde_schema_versions (dataset_id, version, schema_json, created_at) VALUES (?, 1, ?, ?)",
        [dataset_id, schema_json, created_at]
      )
      database.execute(create_table_sql(table_name, definition))
      create_indexes(database, table_name, definition)
    rescue sqlite_exception => error
      raise DatasetConflict, "could not create dataset: #{safe_sqlite_message(error)}"
    end

    def dataset(database, dataset_id)
      row = database.get_first_row("SELECT * FROM sde_datasets WHERE dataset_id = ?", [dataset_id])
      row && stringify_row(row)
    end

    def datasets(database)
      database.execute("SELECT * FROM sde_datasets ORDER BY dataset_id").map { |row| stringify_row(row) }
    end

    def add_schema_version(database, dataset_id:, definition:, version:, added_columns:)
      record = dataset(database, dataset_id) || raise(DatasetNotFound, "dataset storage is missing: #{dataset_id}")
      table_name = record.fetch("table_name")
      added_columns.each do |column|
        database.execute("ALTER TABLE #{quote_identifier(table_name)} ADD COLUMN #{column_sql(database, column)}")
        create_column_index(database, table_name, column) if column.indexed?
      end
      schema_json = JSON.generate(definition.to_h)
      now = timestamp
      database.execute(
        "INSERT INTO sde_schema_versions (dataset_id, version, schema_json, created_at) VALUES (?, ?, ?, ?)",
        [dataset_id, version, schema_json, now]
      )
      database.execute(
        "UPDATE sde_datasets SET schema_version = ?, schema_json = ?, updated_at = ? WHERE dataset_id = ?",
        [version, schema_json, now, dataset_id]
      )
    rescue sqlite_exception => error
      raise MigrationError, safe_sqlite_message(error)
    end

    def record_activity(database, dataset_id:, action:, row_id:, actor_id:, source:,
                        observation_id: nil, proposal_id: nil, approval_id: nil, run_id: nil,
                        activity_id: nil, created_at: timestamp)
      activity_id ||= KnowledgeGraph::IdGenerator.new(clock: @clock).generate("dataevt")
      sql = <<~SQL
        INSERT INTO sde_activity
          (activity_id, dataset_id, action, row_id, created_at, actor_id, source,
           observation_id, proposal_id, approval_id, run_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      database.execute(
        sql, [activity_id, dataset_id, action, row_id, created_at, actor_id, source,
              observation_id, proposal_id, approval_id, run_id]
      )
      activity_id
    end

    def activities(database)
      database.execute("SELECT * FROM sde_activity ORDER BY created_at, activity_id").map do |row|
        stringify_row(row)
      end
    end

    def schema_versions(database, dataset_id)
      database.execute(
        "SELECT version, schema_json, created_at FROM sde_schema_versions WHERE dataset_id = ? ORDER BY version",
        [dataset_id]
      ).map { |row| stringify_row(row) }
    end

    def quote_identifier(value)
      name = Names.identifier!(value)
      %Q{"#{name}"}
    end

    private

    def load_sqlite!
      return if defined?(SQLite3::Database)

      require "sqlite3"
    rescue LoadError
      raise DependencyError, "the sqlite3 Ruby gem is required for dataset commands"
    end

    def sqlite_exception
      load_sqlite!
      SQLite3::Exception
    end

    def migrate_v1(database)
      transaction(database) do
        database.execute_batch(<<~SQL)
          CREATE TABLE sde_datasets (
            dataset_id TEXT PRIMARY KEY,
            table_name TEXT NOT NULL UNIQUE,
            schema_version INTEGER NOT NULL CHECK (schema_version > 0),
            schema_json TEXT NOT NULL CHECK (json_valid(schema_json)),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          );
          CREATE TABLE sde_schema_versions (
            dataset_id TEXT NOT NULL,
            version INTEGER NOT NULL CHECK (version > 0),
            schema_json TEXT NOT NULL CHECK (json_valid(schema_json)),
            created_at TEXT NOT NULL,
            PRIMARY KEY (dataset_id, version),
            FOREIGN KEY (dataset_id) REFERENCES sde_datasets(dataset_id) ON DELETE RESTRICT
          );
          CREATE TABLE sde_activity (
            activity_id TEXT PRIMARY KEY,
            dataset_id TEXT NOT NULL,
            action TEXT NOT NULL CHECK (action IN ('create', 'insert', 'update', 'delete', 'import', 'migrate')),
            row_id TEXT,
            created_at TEXT NOT NULL,
            actor_id TEXT NOT NULL,
            source TEXT NOT NULL,
            observation_id TEXT,
            proposal_id TEXT,
            approval_id TEXT,
            run_id TEXT,
            FOREIGN KEY (dataset_id) REFERENCES sde_datasets(dataset_id) ON DELETE RESTRICT
          );
          CREATE INDEX idx_sde_activity_dataset_time ON sde_activity(dataset_id, created_at);
          PRAGMA user_version = 1;
        SQL
      end
    end

    def migrate_v2(database)
      transaction(database) do
        datasets(database).each do |record|
          table_name = record.fetch("table_name")
          columns = database.execute("PRAGMA table_info(#{quote_identifier(table_name)})").map { |row| row["name"] }
          database.execute("ALTER TABLE #{quote_identifier(table_name)} ADD COLUMN intent_id TEXT") unless columns.include?("intent_id")
          index_name = safe_index_name("idx_#{table_name}_intent_id")
          database.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS #{quote_identifier(index_name)} " \
            "ON #{quote_identifier(table_name)} (intent_id) WHERE intent_id IS NOT NULL"
          )
        end
        database.execute("PRAGMA user_version = 2")
      end
    end

    def create_table_sql(table_name, definition)
      columns = [
        "row_id TEXT PRIMARY KEY",
        *definition.columns.map { |column| column_sql(nil, column) },
        "created_at TEXT NOT NULL",
        "updated_at TEXT NOT NULL",
        "created_by TEXT NOT NULL",
        "source TEXT NOT NULL",
        "observation_id TEXT",
        "proposal_id TEXT",
        "approval_id TEXT",
        "intent_id TEXT"
      ]
      "CREATE TABLE #{quote_identifier(table_name)} (#{columns.join(', ')})"
    end

    def column_sql(database, column)
      sql_type = { "BOOLEAN" => "INTEGER", "DATE" => "TEXT", "DATETIME" => "TEXT", "JSON" => "TEXT" }
                 .fetch(column.type, column.type)
      parts = [quote_identifier(column.name), sql_type]
      parts << "NOT NULL" if column.required?
      parts << "CHECK (#{quote_identifier(column.name)} IN (0, 1))" if column.type == "BOOLEAN"
      parts << "CHECK (json_valid(#{quote_identifier(column.name)}))" if column.type == "JSON"
      parts << "CHECK (#{quote_identifier(column.name)} >= #{column.minimum})" unless column.minimum.nil?
      parts << "CHECK (#{quote_identifier(column.name)} <= #{column.maximum})" unless column.maximum.nil?
      unless column.enum.empty?
        quoted = column.enum.map { |value| database ? database.quote(value) : "'#{value.gsub("'", "''")}'" }
        parts << "CHECK (#{quote_identifier(column.name)} IN (#{quoted.join(', ')}))"
      end
      parts.join(" ")
    end

    def create_indexes(database, table_name, definition)
      database.execute(
        "CREATE INDEX #{quote_identifier(safe_index_name("idx_#{table_name}_created_at"))} ON #{quote_identifier(table_name)} (created_at)"
      )
      database.execute(
        "CREATE UNIQUE INDEX #{quote_identifier(safe_index_name("idx_#{table_name}_intent_id"))} " \
        "ON #{quote_identifier(table_name)} (intent_id) WHERE intent_id IS NOT NULL"
      )
      definition.columns.each do |column|
        create_column_index(database, table_name, column) if column.indexed?
      end
    end

    def create_column_index(database, table_name, column)
      index_name = safe_index_name("idx_#{table_name}_#{column.name}")
      unique = column.unique? ? "UNIQUE " : ""
      database.execute(
        "CREATE #{unique}INDEX #{quote_identifier(index_name)} ON #{quote_identifier(table_name)} (#{quote_identifier(column.name)})"
      )
    end

    def stringify_row(row)
      row.each_with_object({}) do |(key, value), result|
        result[key.to_s] = value unless key.is_a?(Integer)
      end
    end

    def safe_index_name(value)
      return value if value.length <= 63

      "#{value[0, 46]}_#{Digest::SHA256.hexdigest(value)[0, 16]}"
    end

    def timestamp
      @clock.call.iso8601(6)
    end

    def safe_sqlite_message(error)
      error.message.to_s.gsub(path.to_s, "[dataset database]")
    end
  end
end
