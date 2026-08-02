# frozen_string_literal: true

require "json"
require "pathname"
require "time"

module StructuredDataset
  class Registry
    def initialize(vault_root:)
      @vault_root = Pathname.new(vault_root).expand_path
    end

    def all
      records = []
      repository.each_record do |record|
        records << record if record.type == "dataset" && record.data["record_status"] == "active"
      end
      records.sort_by { |record| [record.data["dataset_slug"].to_s, record.id] }
    end

    def resolve(reference)
      value = reference.to_s
      matches = all.select do |record|
        record.id == value || record.data["dataset_slug"] == value || record.data["name"].to_s.casecmp?(value)
      end
      raise DatasetNotFound, "dataset not found: #{reference}" if matches.empty?
      raise DatasetConflict, "dataset reference is ambiguous: #{reference}" if matches.length > 1

      matches.first
    end

    def owner_attributes(owner_id)
      return {} if owner_id.nil? || owner_id.to_s.strip.empty?

      owner = repository.resolve(owner_id)
      { owner: owner.link, owner_id: owner.id }
    rescue KnowledgeGraph::Error => error
      raise InvalidSchema, "dataset owner is invalid: #{error.message}"
    end

    private

    def repository
      KnowledgeGraph::Repository.new(
        vault_root: @vault_root,
        registry: KnowledgeGraph::SchemaRegistry.new(vault_root: @vault_root)
      )
    end
  end

  class Engine
    attr_reader :database

    def initialize(vault_root:, run_id: nil, actor_id: nil, event_bus: nil, clock: nil,
                   database_path: nil, graph_engine: nil)
      @vault_root = Pathname.new(vault_root).expand_path
      @clock = clock || -> { Time.now }
      @id_generator = KnowledgeGraph::IdGenerator.new(clock: @clock)
      @run_id = (run_id || @id_generator.generate("run")).to_s.freeze
      @actor_id = actor_id.to_s.empty? ? "local-cli" : actor_id.to_s
      @event_bus = event_bus
      @registry = Registry.new(vault_root: @vault_root)
      @database = Database.new(vault_root: @vault_root, path: database_path, clock: @clock)
      @database.migrate!
      @graph_engine = graph_engine
      unless @graph_engine
        @graph_engine = KnowledgeGraph::Engine.new(
          vault_root: @vault_root, run_id: @run_id, actor_id: @actor_id, clock: @clock
        )
        @graph_engine = KnowledgeOrchestration::EngineEventBridge.new(event_bus: @event_bus).attach(@graph_engine) if @event_bus
      end
    end

    def create(reference, schema: nil, name: nil, purpose: nil, owner_id: nil,
               sensitivity: nil, kind: nil, dataset_id: nil, provenance: {},
               template_id: nil, template_version: nil, template_digest: nil)
      generated_dataset_id = dataset_id
      slug = Names.slug(reference)
      raise DatasetConflict, "dataset already exists: #{slug}" if @registry.all.any? { |item| item.data["dataset_slug"] == slug }

      base = schema ? definition_from(schema, slug: slug) : Builtins.fetch(slug)
      raise InvalidSchema, "custom datasets require --schema" unless base
      definition = Definition.from_h(
        base.to_h.merge(
          slug: slug, name: name || base.name, purpose: purpose || base.purpose,
          sensitivity: sensitivity || base.sensitivity, kind: kind || base.kind
        )
      )
      generated_dataset_id ||= @id_generator.generate("dataset")
      audit = audit_values(provenance)
      attributes = {
        id: generated_dataset_id, name: definition.name, dataset_slug: definition.slug,
        dataset_kind: definition.kind, storage_backend: "sqlite", storage_table: definition.slug,
        purpose: definition.purpose, sensitivity: definition.sensitivity,
        data_origin: "given_by_subject"
      }.merge(@registry.owner_attributes(owner_id))
      attributes[:dataset_template] = template_id.to_s unless template_id.to_s.empty?
      attributes[:dataset_template_version] = template_version.to_s unless template_version.to_s.empty?
      attributes[:dataset_template_digest] = template_digest.to_s unless template_digest.to_s.empty?
      graph_result = nil
      activity_id = nil
      database.with_connection do |connection|
        database.transaction(connection) do
          database.create_dataset(
            connection, dataset_id: generated_dataset_id, table_name: definition.slug, definition: definition
          )
          graph_result = @graph_engine.execute(
            KnowledgeGraph::CreateEntity.new(
              entity_type: "dataset", attributes: attributes, intent_id: audit["intent_id"]
            )
          )
          activity_id = database.record_activity(
            connection, dataset_id: generated_dataset_id, action: "create", row_id: nil,
            actor_id: audit.fetch("created_by"), source: audit.fetch("source"),
            observation_id: audit["observation_id"], proposal_id: audit["proposal_id"],
            approval_id: audit["approval_id"], run_id: @run_id
          )
        end
      end
      publish_change("create", generated_dataset_id, nil, provenance: audit)
      describe(generated_dataset_id).merge(
        "graph_audit_id" => graph_result.audit_id, "dataset_activity_id" => activity_id
      )
    rescue StandardError => error
      compensate_graph_create(graph_result, generated_dataset_id) if graph_result
      raise error
    end

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

    def insert(reference, values, provenance = {})
      record, storage, definition = resolve(reference)
      row = validate_dataset_row!(
        definition, definition.coerce_row(normalize_compatibility_values(definition, values))
      )
      row_id = @id_generator.generate("row")
      audit = audit_values(provenance)
      now = timestamp
      activity_id = nil
      existing = nil
      database.with_connection do |connection|
        database.transaction(connection) do
          if audit["intent_id"]
            existing = connection.get_first_row(
              "SELECT * FROM #{database.quote_identifier(storage.fetch('table_name'))} WHERE intent_id = ?",
              [audit.fetch("intent_id")]
            )
          end
          unless existing
            insert_row(connection, storage.fetch("table_name"), row_id, row, audit, now)
            activity_id = database.record_activity(
              connection, dataset_id: record.id, action: "insert", row_id: row_id,
              actor_id: audit.fetch("created_by"), source: audit.fetch("source"),
              observation_id: audit["observation_id"], proposal_id: audit["proposal_id"],
              approval_id: audit["approval_id"], run_id: @run_id
            )
          end
        end
      end
      if existing
        prior = definition.decode_row(existing)
        activity_id = activity_records.reverse.find do |item|
          item["dataset_id"] == record.id && item["row_id"] == prior["row_id"] && item["action"] == "insert"
        end&.fetch("activity_id", nil)
        return prior.merge("dataset_activity_id" => activity_id, "replayed" => true)
      end
      publish_change("insert", record.id, row_id, provenance: audit)
      query(reference, row_id: row_id, limit: 1).first.merge("dataset_activity_id" => activity_id, "replayed" => false)
    rescue sqlite_error => error
      raise InvalidRow, safe_sqlite_message(error)
    end

    def replace(reference, match:, values:, provenance: {})
      record, storage, definition = resolve(reference)
      replacement = validate_dataset_row!(
        definition, definition.coerce_row(normalize_compatibility_values(definition, values))
      )
      matching = definition.coerce_row(match, partial: true)
      raise InvalidRow, "replace requires at least one matching column" if matching.empty?

      row_id = @id_generator.generate("row")
      audit = audit_values(provenance)
      now = timestamp
      activity_id = nil
      activity_action = nil
      existing = nil
      database.with_connection do |connection|
        database.transaction(connection) do
          if audit["intent_id"]
            existing = connection.get_first_row(
              "SELECT * FROM #{database.quote_identifier(storage.fetch('table_name'))} WHERE intent_id = ?",
              [audit.fetch("intent_id")]
            )
          end
          unless existing
            clauses = matching.keys.map { |key| "#{database.quote_identifier(key)} = ?" }
            connection.execute(
              "DELETE FROM #{database.quote_identifier(storage.fetch('table_name'))} WHERE #{clauses.join(' AND ')}",
              matching.values
            )
            activity_action = connection.changes.positive? ? "update" : "insert"
            insert_row(connection, storage.fetch("table_name"), row_id, replacement, audit, now)
            activity_id = database.record_activity(
              connection, dataset_id: record.id, action: activity_action, row_id: row_id,
              actor_id: audit.fetch("created_by"), source: audit.fetch("source"),
              observation_id: audit["observation_id"], proposal_id: audit["proposal_id"],
              approval_id: audit["approval_id"], run_id: @run_id
            )
          end
        end
      end
      if existing
        prior = definition.decode_row(existing)
        activity_id = activity_records.reverse.find do |item|
          item["dataset_id"] == record.id && item["row_id"] == prior["row_id"] &&
            %w[insert update].include?(item["action"])
        end&.fetch("activity_id", nil)
        return prior.merge("dataset_activity_id" => activity_id, "replayed" => true)
      end
      publish_change(activity_action, record.id, row_id, provenance: audit)
      query(reference, row_id: row_id, limit: 1).first.merge(
        "dataset_activity_id" => activity_id, "replayed" => false
      )
    rescue sqlite_error => error
      raise InvalidRow, safe_sqlite_message(error)
    end

    def update(reference, row_id, values, provenance = {})
      record, storage, definition = resolve(reference)
      if definition.slug == "medication_schedules" && values.keys.map(&:to_s).include?("schedule_id")
        raise InvalidRow, "schedule_id is immutable"
      end
      row = validate_dataset_row!(
        definition, definition.coerce_row(values, partial: true), partial: true
      )
      raise InvalidRow, "update requires at least one column" if row.empty?

      audit = audit_values(provenance)
      now = timestamp
      database.with_connection do |connection|
        database.transaction(connection) do
          assignments = row.keys.map { |key| "#{database.quote_identifier(key)} = ?" }
          assignments << "updated_at = ?"
          binds = row.values + [now, row_id.to_s]
          connection.execute(
            "UPDATE #{database.quote_identifier(storage.fetch('table_name'))} SET #{assignments.join(', ')} WHERE row_id = ?",
            binds
          )
          raise RowNotFound, "row not found: #{row_id}" if connection.changes.zero?

          database.record_activity(
            connection, dataset_id: record.id, action: "update", row_id: row_id,
            actor_id: audit.fetch("created_by"), source: audit.fetch("source"),
            observation_id: audit["observation_id"], proposal_id: audit["proposal_id"],
            approval_id: audit["approval_id"], run_id: @run_id
          )
        end
      end
      publish_change("update", record.id, row_id, provenance: audit)
      query(reference, row_id: row_id, limit: 1).first
    rescue sqlite_error => error
      raise InvalidRow, safe_sqlite_message(error)
    end

    def delete(reference, row_id, provenance = {})
      record, storage, _definition = resolve(reference)
      audit = audit_values(provenance)
      database.with_connection do |connection|
        database.transaction(connection) do
          connection.execute(
            "DELETE FROM #{database.quote_identifier(storage.fetch('table_name'))} WHERE row_id = ?", [row_id.to_s]
          )
          raise RowNotFound, "row not found: #{row_id}" if connection.changes.zero?

          database.record_activity(
            connection, dataset_id: record.id, action: "delete", row_id: row_id,
            actor_id: audit.fetch("created_by"), source: audit.fetch("source"),
            observation_id: audit["observation_id"], proposal_id: audit["proposal_id"],
            approval_id: audit["approval_id"], run_id: @run_id
          )
        end
      end
      publish_change("delete", record.id, row_id, provenance: audit)
      { "dataset_id" => record.id, "row_id" => row_id.to_s, "deleted" => true }
    end

    def query(reference, where: nil, order: nil, limit: 100, offset: 0, columns: nil, row_id: nil)
      _record, storage, definition = resolve(reference)
      database.with_connection do |connection|
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
      database.with_connection do |connection|
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

    def explain(reference, row_id: nil, where: nil)
      record, storage, definition = resolve(reference)
      query = Query.new(
        database: database, definition: definition, table_name: storage.fetch("table_name"),
        where: where, row_id: row_id, limit: 1
      )
      plan = database.with_connection do |connection|
        connection.execute("EXPLAIN QUERY PLAN #{query.sql}", query.binds).map do |item|
          item.each_with_object({}) { |(key, value), result| result[key.to_s] = value unless key.is_a?(Integer) }
        end
      end
      {
        "dataset" => public_registry(record), "schema_version" => storage.fetch("schema_version"),
        "query_plan" => plan, "safe_query" => { "where" => where, "row_id" => row_id },
        "traceability" => Definition::RESERVED_COLUMNS,
        "boundary" => "SQLite stores rows; the canonical Dataset note stores semantic identity and purpose."
      }
    end

    def migrate(reference, schema, provenance = {})
      record, storage, current = resolve(reference)
      replacement = definition_from(schema, slug: current.slug)
      validate_additive_migration!(current, replacement)
      added = replacement.columns[current.columns.length..-1] || []
      return describe(reference) if added.empty?

      audit = audit_values(provenance)
      next_version = storage.fetch("schema_version").to_i + 1
      activity_id = nil
      database.with_connection do |connection|
        database.transaction(connection) do
          database.add_schema_version(
            connection, dataset_id: record.id, definition: replacement,
            version: next_version, added_columns: added
          )
          activity_id = database.record_activity(
            connection, dataset_id: record.id, action: "migrate", row_id: nil,
            actor_id: audit.fetch("created_by"), source: audit.fetch("source"),
            observation_id: audit["observation_id"], proposal_id: audit["proposal_id"],
            approval_id: audit["approval_id"], run_id: @run_id
          )
        end
      end
      publish_change("migrate", record.id, nil, provenance: audit)
      describe(reference).merge("dataset_activity_id" => activity_id)
    end

    def migrate_medication_schedules(reference, schema, provenance = {})
      record, storage, current = resolve(reference)
      unless MedicationScheduleSchemaMigration.legacy?(current)
        raise MigrationError, "medication schedule migration requires the legacy schedule schema"
      end
      replacement = definition_from(schema, slug: current.slug)
      unless replacement.to_h == MedicationScheduleSchemaMigration.target(current).to_h
        raise MigrationError, "medication schedule migration target does not match the SDK schema"
      end

      audit = audit_values(provenance)
      next_version = storage.fetch("schema_version").to_i + 1
      activity_id = nil
      database.with_connection do |connection|
        database.transaction(connection) do
          database.replace_schema_version(
            connection, dataset_id: record.id, definition: replacement, version: next_version
          ) { |row| MedicationScheduleSchemaMigration.transform(row) }
          activity_id = database.record_activity(
            connection, dataset_id: record.id, action: "migrate", row_id: nil,
            actor_id: audit.fetch("created_by"), source: audit.fetch("source"),
            observation_id: audit["observation_id"], proposal_id: audit["proposal_id"],
            approval_id: audit["approval_id"], run_id: @run_id
          )
        end
      end
      publish_change("migrate", record.id, nil, provenance: audit)
      describe(reference).merge("dataset_activity_id" => activity_id)
    end

    # Atomically closes matching immutable schedule versions and inserts their
    # successor. This is generic Dataset behavior; medication semantics remain
    # in the trusted route handler.
    def evolve(reference, match:, close_values:, values:, provenance: {}, require_match: true)
      record, storage, definition = resolve(reference)
      matching = definition.coerce_row(match, partial: true)
      closing = definition.coerce_row(close_values, partial: true)
      replacement = validate_dataset_row!(definition, definition.coerce_row(values))
      raise InvalidRow, "evolve requires at least one matching column" if matching.empty?
      raise InvalidRow, "evolve requires at least one closing column" if closing.empty?

      row_id = @id_generator.generate("row")
      audit = audit_values(provenance)
      now = timestamp
      existing = nil
      matched = 0
      activity_id = nil
      database.with_connection do |connection|
        database.transaction(connection) do
          if audit["intent_id"]
            existing = connection.get_first_row(
              "SELECT * FROM #{database.quote_identifier(storage.fetch('table_name'))} WHERE intent_id = ?",
              [audit.fetch("intent_id")]
            )
          end
          unless existing
            clause, binds = matching_clause(matching)
            matched = connection.get_first_value(
              "SELECT COUNT(*) FROM #{database.quote_identifier(storage.fetch('table_name'))} WHERE #{clause}", binds
            ).to_i
            raise RowNotFound, "no schedule version matched the approved evolution" if require_match && matched.zero?

            unless matched.zero?
              assignments = closing.keys.map { |key| "#{database.quote_identifier(key)} = ?" }
              assignments << "updated_at = ?"
              connection.execute(
                "UPDATE #{database.quote_identifier(storage.fetch('table_name'))} " \
                "SET #{assignments.join(', ')} WHERE #{clause}",
                closing.values + [now] + binds
              )
            end
            insert_row(connection, storage.fetch("table_name"), row_id, replacement, audit, now)
            activity_id = database.record_activity(
              connection, dataset_id: record.id, action: matched.positive? ? "update" : "insert",
              row_id: row_id, actor_id: audit.fetch("created_by"), source: audit.fetch("source"),
              observation_id: audit["observation_id"], proposal_id: audit["proposal_id"],
              approval_id: audit["approval_id"], run_id: @run_id
            )
          end
        end
      end
      if existing
        return definition.decode_row(existing).merge(
          "dataset_activity_id" => nil, "replayed" => true, "closed_rows" => 0
        )
      end
      publish_change(matched.positive? ? "update" : "insert", record.id, row_id, provenance: audit)
      query(reference, row_id: row_id, limit: 1).first.merge(
        "dataset_activity_id" => activity_id, "replayed" => false, "closed_rows" => matched
      )
    rescue sqlite_error => error
      raise InvalidRow, safe_sqlite_message(error)
    end

    def update_matching_ids(reference, identifier:, ids:, values:, provenance: {})
      record, storage, definition = resolve(reference)
      column = definition.column(identifier)
      identifiers = Array(ids).map { |value| column.coerce(value) }.uniq
      changes = definition.coerce_row(values, partial: true)
      raise InvalidRow, "update_matching_ids requires IDs" if identifiers.empty?
      raise InvalidRow, "update_matching_ids requires changed columns" if changes.empty?

      audit = audit_values(provenance)
      now = timestamp
      count = 0
      activity_id = nil
      database.with_connection do |connection|
        database.transaction(connection) do
          assignments = changes.keys.map { |key| "#{database.quote_identifier(key)} = ?" }
          assignments << "updated_at = ?"
          connection.execute(
            "UPDATE #{database.quote_identifier(storage.fetch('table_name'))} " \
            "SET #{assignments.join(', ')} WHERE #{database.quote_identifier(column.name)} " \
            "IN (#{(['?'] * identifiers.length).join(', ')})",
            changes.values + [now] + identifiers
          )
          count = connection.changes
          unless count == identifiers.length
            raise RowNotFound, "not every approved Dataset row matched the update"
          end
          activity_id = database.record_activity(
            connection, dataset_id: record.id, action: "update", row_id: nil,
            actor_id: audit.fetch("created_by"), source: audit.fetch("source"),
            observation_id: audit["observation_id"], proposal_id: audit["proposal_id"],
            approval_id: audit["approval_id"], run_id: @run_id
          )
        end
      end
      publish_change("update", record.id, nil, provenance: audit, row_count: count)
      {
        "dataset_id" => record.id, "updated" => count,
        "dataset_activity_id" => activity_id, "replayed" => false
      }
    rescue sqlite_error => error
      raise InvalidRow, safe_sqlite_message(error)
    end

    def import_rows(reference, rows, provenance = {})
      record, storage, definition = resolve(reference)
      audit = audit_values(provenance)
      prepared = Array(rows).map do |row|
        values = row.each_with_object({}) do |(key, value), result|
          result[key] = value unless Definition::RESERVED_COLUMNS.include?(key.to_s) || key.to_s == "dataset_activity_id"
        end
        validate_dataset_row!(
          definition, definition.coerce_row(normalize_compatibility_values(definition, values))
        )
      end
      inserted = []
      now = timestamp
      database.with_connection do |connection|
        database.transaction(connection) do
          prepared.each do |row|
            row_id = @id_generator.generate("row")
            insert_row(connection, storage.fetch("table_name"), row_id, row, audit, now)
            inserted << row_id
          end
          database.record_activity(
            connection, dataset_id: record.id, action: "import", row_id: nil,
            actor_id: audit.fetch("created_by"), source: audit.fetch("source"),
            observation_id: audit["observation_id"], proposal_id: audit["proposal_id"],
            approval_id: audit["approval_id"], run_id: @run_id
          )
        end
      end
      publish_change("import", record.id, nil, provenance: audit, row_count: inserted.length)
      { "dataset_id" => record.id, "inserted" => inserted.length, "row_ids" => inserted }
    rescue sqlite_error => error
      raise ImportError, safe_sqlite_message(error)
    end

    def activity_records
      database.with_connection { |connection| database.activities(connection) }
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
      database.with_connection { |connection| database.dataset(connection, dataset_id) }
    end

    def schema_history(dataset_id)
      database.with_connection do |connection|
        database.schema_versions(connection, dataset_id).map do |item|
          { "version" => item.fetch("version"), "created_at" => item.fetch("created_at") }
        end
      end
    end

    def definition_from(value, slug:)
      data = case value
             when Definition then value.to_h
             when Hash then value
             when String then JSON.parse(value)
             else raise InvalidSchema, "schema must be a JSON object"
             end
      normalized = data.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      normalized["slug"] ||= slug
      normalized["kind"] ||= "custom"
      normalized["name"] ||= slug.split("_").map(&:capitalize).join(" ")
      normalized["purpose"] ||= "Custom structured dataset"
      normalized["sensitivity"] ||= "private"
      Definition.from_h(normalized)
    rescue JSON::ParserError => error
      raise InvalidSchema, "schema JSON is invalid: #{error.message}"
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

    def audit_values(provenance)
      data = provenance.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      source = data.fetch("source", "dataset-cli").to_s.strip
      actor = data.fetch("created_by", @actor_id).to_s.strip
      raise InvalidRow, "source is required" if source.empty?
      raise InvalidRow, "created_by is required" if actor.empty?

      {
        "created_by" => actor,
        "source" => source,
        "observation_id" => optional_id(data["observation_id"]),
        "proposal_id" => optional_id(data["proposal_id"]),
        "approval_id" => optional_id(data["approval_id"]),
        "intent_id" => optional_id(data["intent_id"]),
        "evidence_id" => optional_id(data["evidence_id"]),
        "source_uri" => optional_text(data["source_uri"]),
        "source_filename" => optional_text(data["source_filename"]),
        "source_page" => optional_integer(data["source_page"]),
        "source_span" => optional_text(data["source_span"])
      }
    end

    def optional_id(value)
      value.nil? || value.to_s.strip.empty? ? nil : value.to_s
    end

    def optional_text(value)
      value.nil? || value.to_s.strip.empty? ? nil : value.to_s
    end

    def optional_integer(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Integer(value)
    rescue ArgumentError, TypeError
      raise InvalidRow, "source_page must be an integer"
    end

    def insert_row(connection, table_name, row_id, row, audit, now)
      values = {
        "row_id" => row_id
      }.merge(row).merge(
        "created_at" => now, "updated_at" => now,
        "created_by" => audit.fetch("created_by"), "source" => audit.fetch("source"),
        "observation_id" => audit["observation_id"], "proposal_id" => audit["proposal_id"],
        "approval_id" => audit["approval_id"], "intent_id" => audit["intent_id"],
        "evidence_id" => audit["evidence_id"], "source_uri" => audit["source_uri"],
        "source_filename" => audit["source_filename"], "source_page" => audit["source_page"],
        "source_span" => audit["source_span"]
      )
      columns = values.keys
      sql = "INSERT INTO #{database.quote_identifier(table_name)} " \
            "(#{columns.map { |key| database.quote_identifier(key) }.join(', ')}) " \
            "VALUES (#{(['?'] * columns.length).join(', ')})"
      connection.execute(sql, columns.map { |key| values[key] })
    end

    def matching_clause(values)
      clauses = []
      binds = []
      values.each do |key, value|
        if value.nil?
          clauses << "#{database.quote_identifier(key)} IS NULL"
        else
          clauses << "#{database.quote_identifier(key)} = ?"
          binds << value
        end
      end
      [clauses.join(" AND "), binds]
    end

    def validate_dataset_row!(definition, row, partial: false)
      return row unless definition.slug == "medication_schedules"

      MedicationScheduleOperations.validate_row!(row, partial: partial)
    end

    def normalize_compatibility_values(definition, values)
      data = values.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      return data unless definition.slug == "blood_tests"

      data["analyte"] ||= data["marker"] if definition.column?("analyte")
      data["marker"] ||= data["analyte"] if definition.column?("marker")
      if definition.column?("test_date") && data["test_date"].nil? && data["observed_at"]
        data["test_date"] = data["observed_at"].to_s[0, 10]
      end
      if definition.column?("observed_at") && data["observed_at"].nil? && data["test_date"]
        data["observed_at"] = "#{data['test_date']}T00:00:00Z"
      end
      data["unit"] ||= "unspecified" if definition.column?("unit")
      data
    end

    def validate_additive_migration!(current, replacement)
      unless current.slug == replacement.slug && current.name == replacement.name &&
             current.kind == replacement.kind && current.purpose == replacement.purpose &&
             current.sensitivity == replacement.sensitivity
        raise MigrationError, "schema migration cannot change dataset registry metadata"
      end
      if replacement.columns.length < current.columns.length
        raise MigrationError, "destructive column removal is not supported"
      end
      current.columns.each_with_index do |column, index|
        unless column.to_h == replacement.columns[index].to_h
          raise MigrationError, "existing column #{column.name} cannot be changed or reordered"
        end
      end
      added = replacement.columns[current.columns.length..-1] || []
      if added.any?(&:required?)
        raise MigrationError, "new columns must be optional to preserve existing rows"
      end
    end

    def publish_change(action, dataset_id, row_id, provenance: {}, row_count: nil)
      return unless @event_bus

      payload = {
        "dataset_id" => dataset_id, "action" => action, "row_id" => row_id,
        "row_count" => row_count, "observation_id" => provenance["observation_id"],
        "proposal_id" => provenance["proposal_id"], "approval_id" => provenance["approval_id"]
      }.reject { |_key, value| value.nil? }
      @event_bus.publish(
        type: "DatasetChanged", source: "structured-dataset-engine", payload: payload,
        correlation_id: @run_id
      )
    rescue KnowledgeOrchestration::Error
      nil
    end

    def compensate_graph_create(graph_result, dataset_id)
      return unless graph_result && !graph_result.replayed

      @graph_engine.execute(KnowledgeGraph::ArchiveEntity.new(entity_id: dataset_id))
    rescue StandardError => error
      raise ConsistencyError, "dataset creation failed and graph compensation failed: #{error.message}"
    end

    def sqlite_error
      defined?(SQLite3::Exception) ? SQLite3::Exception : StandardError
    end

    def safe_sqlite_message(error)
      error.message.to_s.gsub(database.path.to_s, "[dataset database]")
    end

    def timestamp
      @clock.call.iso8601(6)
    end
  end
end
