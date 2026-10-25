# frozen_string_literal: true

module StructuredDataset
  # Shares Engine read semantics, but has no writer, Engine, receipt or event bridge.
  class Reader
    include ReadOperations

    CATALOG = {
      "sde_datasets" => %w[dataset_id table_name schema_version schema_json created_at updated_at],
      "sde_schema_versions" => %w[dataset_id version schema_json created_at],
      "sde_activity" => %w[activity_id dataset_id action row_id created_at actor_id source observation_id proposal_id approval_id run_id]
    }.freeze

    def initialize(vault_root:, database_path:, clock: nil)
      @registry = Registry.new(vault_root: vault_root)
      @database = Database.new(vault_root: vault_root, path: database_path, clock: clock)
      @connection_key = "structured_dataset_reader_#{object_id}".to_sym
    end

    def availability
      with_consistent_read { { "status" => "ready", "code" => nil, "engine_schema_version" => Database::ENGINE_SCHEMA_VERSION } }
    rescue StorageUnavailable => error
      { "status" => "unavailable", "code" => error.code }
    end

    # Thread-scoped reentrancy pins all reads in a report to one SQLite snapshot.
    def with_consistent_read
      return yield self if Thread.current[@connection_key]

      @database.with_read_connection do |connection|
        validate_storage!(connection)
        Thread.current[@connection_key] = connection
        begin
          yield self
        ensure
          Thread.current[@connection_key] = nil
        end
      end
    end

    ReadOperations.public_instance_methods(false).each do |name|
      define_method(name) do |*arguments, **options|
        with_consistent_read do
          options.empty? ? super(*arguments) : super(*arguments, **options)
        end
      end
    end

    private

    attr_reader :database

    def with_read_source
      with_consistent_read { yield Thread.current[@connection_key] }
    end

    def validate_storage!(connection)
      version = connection.get_first_value("PRAGMA user_version").to_i
      raise StorageUnavailable, "dataset_upgrade_required" if version < Database::ENGINE_SCHEMA_VERSION
      raise StorageUnavailable, "dataset_engine_too_old" if version > Database::ENGINE_SCHEMA_VERSION

      CATALOG.each do |table, required|
        columns = connection.execute("PRAGMA table_info(#{database.quote_identifier(table)})").map { |row| row["name"] }
        raise StorageUnavailable, "dataset_storage_invalid" unless (required - columns).empty?
      end
      database.datasets(connection).each do |record|
        definition = Definition.from_h(JSON.parse(record.fetch("schema_json")))
        table = database.quote_identifier(record.fetch("table_name"))
        columns = connection.execute("PRAGMA table_info(#{table})").map { |row| row["name"] }
        required = definition.columns.map(&:name) + Definition::RESERVED_COLUMNS
        raise StorageUnavailable, "dataset_storage_invalid" unless (required - columns).empty?
      end
    rescue InvalidSchema, JSON::ParserError, KeyError, ArgumentError
      raise StorageUnavailable, "dataset_storage_invalid"
    end

    def sqlite_error
      database.send(:sqlite_exception)
    end

    def safe_sqlite_message(_error)
      "dataset read failed"
    end
  end
end
