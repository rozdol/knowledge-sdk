# frozen_string_literal: true

require "date"
require "time"

module StructuredDataset
  class EvolutionPlan
    attr_reader :kind, :dataset, :definition, :intent, :added_columns

    def initialize(kind:, dataset:, definition:, intent: nil, added_columns: [])
      @kind = kind.to_s.freeze
      @dataset = dataset.to_s.freeze
      @definition = definition
      @intent = intent
      @added_columns = Array(added_columns).map(&:to_s).freeze
      freeze
    end

    def prerequisite?
      !intent.nil?
    end

    def proposal_type
      self.class.name.split("::").last
    end

    def to_h
      {
        "kind" => kind, "proposal_type" => proposal_type, "dataset" => dataset,
        "schema" => definition.to_h, "added_columns" => added_columns,
        "approval_required" => prerequisite?
      }
    end
  end

  class CreateDatasetProposal < EvolutionPlan; end
  class DatasetSchemaUpgradeProposal < EvolutionPlan; end
  class CurrentDatasetPlan < EvolutionPlan; end

  # Read-only lifecycle planner for the Dataset registry. It never changes the
  # graph or SQLite; it emits immutable lifecycle Intents for the existing
  # Proposal -> Approval -> Engine path.
  class AutonomousRegistry
    RESERVED = Definition::RESERVED_COLUMNS.freeze

    def initialize(vault_root:, engine: nil, clock: nil)
      @engine = engine || Engine.new(vault_root: vault_root, clock: clock)
      @clock = clock || -> { Time.now }
    end

    def plan(dataset:, values:, schema: nil, source: "dataset-registry", proposal_id: nil,
             dataset_id: nil)
      slug = Names.slug(dataset)
      row = stringify(values)
      description = @engine.describe(slug)
      current = definition_from_description(description)
      if slug == "medication_schedules" && MedicationScheduleSchemaMigration.legacy?(current)
        replacement = MedicationScheduleSchemaMigration.target(current)
        added = replacement.columns.map(&:name) - current.columns.map(&:name)
        intent = KnowledgeGraph::UpgradeDatasetSchema.new(
          dataset: slug, from_version: description.fetch("schema_version"),
          schema: replacement.to_h, added_columns: added.sort,
          migration_id: MedicationScheduleSchemaMigration::ID,
          source: source, proposal_id: proposal_id
        )
        return DatasetSchemaUpgradeProposal.new(
          kind: "schema_migration", dataset: slug, definition: replacement,
          intent: intent, added_columns: added.sort
        )
      end
      unknown = unknown_columns(current, row)
      return CurrentDatasetPlan.new(kind: "current", dataset: slug, definition: current) if unknown.empty?

      replacement = append_columns(current, unknown, row)
      intent = KnowledgeGraph::UpgradeDatasetSchema.new(
        dataset: slug, from_version: description.fetch("schema_version"),
        schema: replacement.to_h, added_columns: unknown.sort,
        source: source, proposal_id: proposal_id
      )
      DatasetSchemaUpgradeProposal.new(
        kind: "schema_upgrade", dataset: slug, definition: replacement,
        intent: intent, added_columns: unknown.sort
      )
    rescue DatasetNotFound
      definition = initial_definition(slug, schema, row)
      identifier = dataset_id || KnowledgeGraph::IdGenerator.new(clock: @clock).generate("dataset")
      intent = KnowledgeGraph::CreateDataset.new(
        dataset_id: identifier, dataset: slug, schema: definition.to_h,
        source: source, proposal_id: proposal_id
      )
      CreateDatasetProposal.new(
        kind: "create", dataset: slug, definition: definition, intent: intent,
        added_columns: definition.columns.map(&:name)
      )
    end

    private

    def initial_definition(slug, schema, row)
      base = if schema
               definition_from_value(schema, slug)
             else
               Builtins.fetch(slug)
             end
      if base
        unknown = unknown_columns(base, row)
        return unknown.empty? ? base : append_columns(base, unknown, row)
      end
      raise InvalidSchema, "cannot infer an empty Dataset schema" if row.empty?

      Definition.from_h(
        slug: slug, name: title(slug), kind: slug,
        purpose: "Structured observations for #{title(slug)}", sensitivity: "private",
        columns: row.keys.sort.map { |name| inferred_column(name, row.fetch(name)) }
      )
    end

    def definition_from_value(value, slug)
      data = value.is_a?(Definition) ? value.to_h : value
      raise InvalidSchema, "dataset schema must be an object" unless data.is_a?(Hash)

      normalized = stringify(data)
      normalized["slug"] ||= slug
      normalized["name"] ||= title(slug)
      normalized["kind"] ||= slug
      normalized["purpose"] ||= "Structured observations for #{title(slug)}"
      normalized["sensitivity"] ||= "private"
      Definition.from_h(normalized)
    end

    def definition_from_description(description)
      Definition.from_h(
        slug: description.fetch("slug"), name: description.fetch("name"),
        kind: description.fetch("kind"), purpose: description.fetch("purpose"),
        sensitivity: description.fetch("sensitivity"), columns: description.fetch("columns")
      )
    end

    def unknown_columns(definition, row)
      row.keys.reject { |name| RESERVED.include?(name) || definition.column?(name) }.sort
    end

    def append_columns(definition, names, row)
      Definition.from_h(
        definition.to_h.merge(
          columns: definition.columns.map(&:to_h) + names.sort.map do |name|
            inferred_column(name, row.fetch(name))
          end
        )
      )
    end

    def inferred_column(name, value)
      identifier = Names.identifier!(name, "column name")
      type = case value
             when true, false then "BOOLEAN"
             when Integer then "INTEGER"
             when Float then "REAL"
             when Hash, Array then "JSON"
             else temporal_type(value) || "TEXT"
             end
      { name: identifier, type: type, required: false }
    end

    def temporal_type(value)
      text = value.to_s
      return "DATE" if text.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(text)
      return "DATETIME" if text.match?(/T/) && Time.iso8601(text)

      nil
    rescue ArgumentError
      nil
    end

    def stringify(value)
      value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
    end

    def title(slug)
      slug.split("_").map { |word| word.capitalize }.join(" ")
    end
  end
end
