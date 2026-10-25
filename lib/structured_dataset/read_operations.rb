# frozen_string_literal: true

module StructuredDataset
  # Shared read semantics; connection lifecycle is supplied by Engine or Reader.
  module ReadOperations
    def list
      @registry.all.map do |record|
        storage = storage_record(record.id)
        public_registry(record).merge(
          "schema_version" => storage && storage.fetch("schema_version"),
          "storage_status" => storage ? "ready" : "missing"
        )
      end
    end

    def describe(reference)
      record, storage, definition = resolve(reference)
      public_registry(record).merge(
        "schema_version" => storage.fetch("schema_version"),
        "columns" => definition.columns.map(&:to_h),
        "audit_columns" => Definition::RESERVED_COLUMNS,
        "schema_history" => schema_history(record.id)
      )
    end

    def query(reference, where: nil, order: nil, limit: 100, offset: 0, columns: nil, row_id: nil)
      _record, storage, definition = resolve(reference)
      with_read_source do |connection|
        selection = Query.new(
          database: database, definition: definition, table_name: storage.fetch("table_name"),
          where: where, order: order, limit: limit, offset: offset, columns: columns, row_id: row_id
        )
        connection.execute(selection.sql, selection.binds).map { |row| definition.decode_row(row) }
      end
    rescue sqlite_error => error
      raise InvalidQuery, safe_sqlite_message(error)
    end

    def stats(reference)
      record, storage, definition = resolve(reference)
      table = database.quote_identifier(storage.fetch("table_name"))
      with_read_source do |connection|
        count = connection.get_first_value("SELECT COUNT(*) FROM #{table}").to_i
        numeric = definition.columns.select { |column| %w[INTEGER REAL].include?(column.type) }.each_with_object({}) do |column, result|
          quoted = database.quote_identifier(column.name)
          row = connection.get_first_row(
            "SELECT MIN(#{quoted}) AS minimum, MAX(#{quoted}) AS maximum, AVG(#{quoted}) AS average FROM #{table}"
          )
          result[column.name] = {
            "minimum" => row["minimum"], "maximum" => row["maximum"],
            "average" => row["average"] && row["average"].round(6)
          }
        end
        temporal = definition.columns.select { |column| %w[DATE DATETIME].include?(column.type) }.each_with_object({}) do |column, result|
          quoted = database.quote_identifier(column.name)
          row = connection.get_first_row("SELECT MIN(#{quoted}) AS earliest, MAX(#{quoted}) AS latest FROM #{table}")
          result[column.name] = { "earliest" => row["earliest"], "latest" => row["latest"] }
        end
        {
          "dataset_id" => record.id, "dataset" => record.data["dataset_slug"],
          "row_count" => count, "numeric" => numeric, "temporal" => temporal
        }
      end
    end

    def activity_records
      with_read_source { |connection| database.activities(connection) }
    end

    def schema_history(dataset_id)
      with_read_source do |connection|
        database.schema_versions(connection, dataset_id).map do |item|
          { "version" => item.fetch("version"), "created_at" => item.fetch("created_at") }
        end
      end
    end

    private

    def resolve(reference)
      record = @registry.resolve(reference)
      storage = storage_record(record.id)
      raise ConsistencyError, "dataset graph record has no SQLite storage: #{record.id}" unless storage
      unless storage.fetch("table_name") == record.data["storage_table"]
        raise ConsistencyError, "dataset registry and SQLite table mapping differ: #{record.id}"
      end

      [record, storage, Definition.from_h(JSON.parse(storage.fetch("schema_json")))]
    end

    def storage_record(dataset_id)
      with_read_source { |connection| database.dataset(connection, dataset_id) }
    end

    def public_registry(record)
      {
        "dataset_id" => record.id, "name" => record.data["name"],
        "slug" => record.data["dataset_slug"], "kind" => record.data["dataset_kind"],
        "storage" => record.data["storage_backend"], "table" => record.data["storage_table"],
        "owner_id" => record.data["owner_id"], "purpose" => record.data["purpose"],
        "sensitivity" => record.data["sensitivity"],
        "template" => record.data["dataset_template"],
        "template_version" => record.data["dataset_template_version"],
        "template_digest" => record.data["dataset_template_digest"],
        "graph_path" => record.relative_path
      }.reject { |_key, value| value.nil? }
    end
  end
end
