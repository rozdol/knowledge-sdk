# frozen_string_literal: true

require "date"
require "time"

module StructuredDataset
  class RoutingRegistry
    Route = Struct.new(
      :intent, :dataset, :intent_class, :builder, :writer, :row_builder,
      keyword_init: true
    )

    def initialize
      @routes = {}
    end

    # Trusted SDK plugins register construction and persistence for a classifier
    # intent. Registration is code-owned; attached Vault data is never loaded.
    def register(intent:, dataset:, intent_class:, builder:, writer:, row_builder: nil)
      intent_name = intent.to_s.strip
      raise ArgumentError, "Dataset route intent is required" if intent_name.empty?
      unless intent_name.start_with?("dataset.")
        raise ArgumentError, "Dataset route intent must use the dataset. namespace"
      end
      unless intent_class.is_a?(Class) && intent_class <= KnowledgeGraph::DatasetIntent
        raise ArgumentError, "Dataset route intent_class must inherit KnowledgeGraph::DatasetIntent"
      end
      unless builder.respond_to?(:call) && writer.respond_to?(:call)
        raise ArgumentError, "Dataset route builder and writer must respond to call"
      end

      existing = @routes[intent_name]
      if existing && (existing.dataset != Names.slug(dataset) || existing.intent_class != intent_class)
        raise DatasetConflict, "Dataset route #{intent_name} conflicts with an existing registration"
      end
      KnowledgeGraph::IntentFactory.register(intent_class)
      @routes[intent_name] = Route.new(
        intent: intent_name.freeze, dataset: Names.slug(dataset).freeze,
        intent_class: intent_class, builder: builder, writer: writer,
        row_builder: row_builder || method(:default_row_values)
      ).freeze
      self
    end

    def fetch(intent)
      @routes.fetch(intent.to_s) do
        raise InvalidRow, "no Dataset route is registered for #{intent}"
      end
    end

    def for_intent(intent)
      @routes.values.find { |route| intent.is_a?(route.intent_class) } ||
        raise(InvalidRow, "no Dataset handler is registered for #{intent.intent_type}")
    end

    def intent_classes
      @routes.values.map(&:intent_class).uniq.freeze
    end

    private

    def default_row_values(intent)
      ignored = %i[intent_id intent_type source observation_id proposal_id]
      intent.to_h.each_with_object({}) do |(key, value), result|
        result[key.to_s] = value unless ignored.include?(key.to_sym) || value.nil?
      end
    end
  end

  class << self
    def routing_registry
      @routing_registry ||= RoutingRegistry.new
    end
  end

  class IntentClassifierPlugin
    LAB_MARKERS = %w[
      ldl hdl cholesterol triglycerides glucose insulin hemoglobin haemoglobin hba1c
      ferritin iron creatinine cortisol testosterone estradiol oestradiol tsh t3 t4
      alt ast bilirubin albumin sodium potassium calcium magnesium vitamin-d b12 crp
    ].freeze
    BODY_MEASUREMENTS = %w[
      waist chest hip hips neck arm thigh calf height body-fat bodyfat
    ].freeze
    TABLE_HEADER = /\b(?:amount|currency|value|unit|marker|measurement|medication|dose|date)\b/i.freeze
    STRUCTURED_UNIT = /(?:\b(?:kg|lbs?|pounds?|cm|mm|bpm|mg|mcg|mg\/dL|mmol\/L|g\/dL|ng\/mL|USD|EUR|GBP)\b|[%$€£₽]|\b(?:кг|см|мм|мг|давление|вес|анализ|измерение|лекарств\w*)\b|(?:πίεση|βάρος|εξέταση|μέτρηση|φάρμακο))/i.freeze

    class << self
      def register(classifier = KnowledgeSDK.intent_classifier)
        classifier.register(name: "structured-dataset-core", route: "dataset") do |text, context|
          new.classify(text, context)
        end
      end
    end

    def classify(text, context = {})
      source = text.to_s.strip
      timestamp = observed_time(context)
      medication(source, timestamp) || blood_pressure(source, timestamp) ||
        weight(source, timestamp) || blood_test(source, timestamp) ||
        body_measurement(source, timestamp) || expense(source, timestamp) ||
        structured_guard(source)
    end

    private

    def medication(source, timestamp)
      pattern = /\bi\s+(?:take|am\s+taking)\s+([a-z][a-z0-9 .'-]*?)(?:\s+(\d+(?:\.\d+)?)\s*(mg|mcg|g|ml))?\s+(every\s+(?:morning|afternoon|evening|night|day)|once\s+daily|twice\s+daily|at\s+\d{1,2}(?::\d{2})?(?:\s*[ap]m)?)\b/i
      match = pattern.match(source)
      return nil unless match

      slots = {
        "medication" => title_word(match[1]), "schedule" => match[4].downcase,
        "effective_on" => timestamp.to_date.iso8601
      }
      slots["dose"] = match[2].to_f if match[2]
      slots["unit"] = match[3].downcase if match[3]
      result(
        "dataset.medication_schedule", 0.98, slots,
        "recognized a recurring medication schedule as structured Dataset data"
      )
    end

    def blood_pressure(source, timestamp)
      pattern = /\b(?:today['’]?s\s+)?(?:my\s+)?blood\s+pressure(?:\s+today)?\s+(?:was|is)\s+(\d{2,3})\s*(?:over|\/)\s*(\d{2,3})(?:\s+(?:with\s+(?:a\s+)?pulse(?:\s+of)?|pulse)\s+(\d{2,3}))?/i
      match = pattern.match(source)
      return nil unless match

      slots = {
        "observed_at" => timestamp.iso8601, "systolic" => match[1].to_i,
        "diastolic" => match[2].to_i
      }
      slots["pulse"] = match[3].to_i if match[3]
      result(
        "dataset.blood_pressure_measurement", 0.99, slots,
        "recognized a blood pressure measurement as structured Dataset data"
      )
    end

    def weight(source, timestamp)
      pattern = /\b(?:today['’]?s\s+)?my\s+weight(?:\s+today)?\s+(?:was|is)\s+(\d+(?:\.\d+)?)\s*(kg|kilograms?|lbs?|pounds?)\b/i
      match = pattern.match(source)
      return nil unless match

      value = match[1].to_f
      kilograms = match[2].downcase.start_with?("kg", "kilogram") ? value : (value * 0.45359237).round(6)
      result(
        "dataset.weight_measurement", 0.98,
        { "observed_at" => timestamp.iso8601, "weight_kg" => kilograms },
        "recognized a body-weight measurement as structured Dataset data"
      )
    end

    def blood_test(source, timestamp)
      pattern = /\b(?:today['’]?s\s+)?(?:my\s+)?(?:blood\s+test\s+(?:for\s+)?)?([a-z][a-z0-9 -]{0,40}?)\s+(?:was|is)\s+(-?\d+(?:\.\d+)?)(?:\s*(mg\/dL|mmol\/L|g\/dL|ng\/mL|pg\/mL|mIU\/L|U\/L|%))?\b/i
      match = pattern.match(source)
      return nil unless match

      marker_key = match[1].strip.downcase.tr(" ", "-")
      explicit_blood_test = source.match?(/\bblood\s+test\b/i)
      return nil unless explicit_blood_test || LAB_MARKERS.include?(marker_key)

      marker = marker_key.length <= 5 ? marker_key.upcase : title_word(match[1])
      slots = {
        "observed_at" => timestamp.iso8601, "marker" => marker,
        "value" => match[2].to_f
      }
      slots["unit"] = match[3] if match[3]
      result(
        "dataset.blood_test_result", 0.97, slots,
        "recognized a laboratory measurement as structured Dataset data"
      )
    end

    def body_measurement(source, timestamp)
      pattern = /\b(?:today['’]?s\s+)?my\s+([a-z -]+?)\s+(?:measurement\s+)?(?:was|is)\s+(\d+(?:\.\d+)?)\s*(cm|mm|m|in|inches|%)\b/i
      match = pattern.match(source)
      return nil unless match

      measurement = match[1].strip.downcase.tr(" ", "-")
      return nil unless BODY_MEASUREMENTS.include?(measurement)

      result(
        "dataset.body_measurement", 0.96,
        {
          "observed_at" => timestamp.iso8601, "measurement" => measurement.tr("-", "_"),
          "value" => match[2].to_f, "unit" => match[3].downcase
        },
        "recognized a physical measurement as structured Dataset data"
      )
    end

    def expense(source, timestamp)
      pattern = /\bi\s+(?:spent|paid)\s+(?:([$€£])\s*)?(\d+(?:\.\d{1,2})?)(?:\s*(USD|EUR|GBP))?\s+(?:on|for)\s+(.+?)[.!]?\z/i
      match = pattern.match(source)
      return nil unless match

      currency = match[3]&.upcase || { "$" => "USD", "€" => "EUR", "£" => "GBP" }[match[1]]
      return structured_guard(source) unless currency

      result(
        "dataset.expense", 0.96,
        {
          "occurred_on" => timestamp.to_date.iso8601, "category" => match[4].strip,
          "amount" => match[2].to_f, "currency" => currency
        },
        "recognized a financial observation as structured Dataset data"
      )
    end

    def structured_guard(source)
      lines = source.lines.map(&:strip).reject(&:empty?)
      table = lines.length >= 2 && TABLE_HEADER.match?(lines.first) &&
              (lines.first.include?("|") || lines.first.include?(","))
      structured_statement = source.match?(
        /(?:\b(?:medication\s+schedule|lab(?:oratory)?\s+(?:result|measurement)|finance\s+table|body\s+measurement)\b|(?:расписание\s+лекарств|лабораторн\w+\s+(?:результат|измерение)|финансов\w+\s+таблиц\w+|измерение\s+тела)|(?:πρόγραμμα\s+φαρμάκων|εργαστηριακ\w+\s+(?:αποτέλεσμα|μέτρηση)|οικονομικ\w+\s+πίνακ\w+|μέτρηση\s+σώματος))/i
      )
      declarative_numeric = !source.end_with?("?") && source.match?(/\d/) && STRUCTURED_UNIT.match?(source)
      return nil unless table || structured_statement || declarative_numeric

      result(
        "dataset.structured_observation", 0.70,
        { "clarification_required" => true },
        "detected structured rows that require a Dataset schema or domain plugin"
      )
    end

    def observed_time(context)
      value = context["captured_at"] || context[:captured_at]
      return Time.now if value.to_s.strip.empty?

      value.is_a?(Time) ? value : Time.iso8601(value.to_s)
    rescue ArgumentError
      Time.now
    end

    def result(intent, confidence, slots, reason)
      { "intent" => intent, "confidence" => confidence, "slots" => slots, "reason" => reason }
    end

    def title_word(value)
      value.to_s.strip.split(/\s+/).map do |word|
        word.empty? ? word : word[0].upcase + word[1..-1].to_s.downcase
      end.join(" ")
    end
  end

  module CoreRoutes
    module_function

    def register(registry = StructuredDataset.routing_registry)
      registry.register(
        intent: "dataset.medication_schedule", dataset: "medication_schedules",
        intent_class: KnowledgeGraph::ReplaceMedicationSchedule,
        builder: ->(common, slots) { KnowledgeGraph::ReplaceMedicationSchedule.new(**common.merge(slots)) },
        writer: lambda do |engine, intent, provenance|
          values = compact(
            effective_on: intent.effective_on, medication: intent.medication,
            dose: intent.dose, unit: intent.unit, schedule: intent.schedule, active: true
          )
          engine.replace(
            "medication_schedules", match: { medication: intent.medication },
            values: values, provenance: provenance
          )
        end
      )
      registry.register(
        intent: "dataset.blood_pressure_measurement", dataset: "blood_pressure",
        intent_class: KnowledgeGraph::InsertBloodPressureMeasurement,
        builder: ->(common, slots) { KnowledgeGraph::InsertBloodPressureMeasurement.new(**common.merge(slots)) },
        writer: lambda do |engine, intent, provenance|
          engine.insert(
            "blood_pressure",
            compact(
              observed_at: intent.observed_at, systolic: intent.systolic,
              diastolic: intent.diastolic, pulse: intent.pulse
            ),
            provenance
          )
        end
      )
      registry.register(
        intent: "dataset.weight_measurement", dataset: "weight",
        intent_class: KnowledgeGraph::InsertWeightMeasurement,
        builder: ->(common, slots) { KnowledgeGraph::InsertWeightMeasurement.new(**common.merge(slots)) },
        writer: lambda do |engine, intent, provenance|
          engine.insert(
            "weight", { observed_at: intent.observed_at, weight_kg: intent.weight_kg }, provenance
          )
        end
      )
      registry.register(
        intent: "dataset.blood_test_result", dataset: "blood_tests",
        intent_class: KnowledgeGraph::InsertBloodTestResult,
        builder: ->(common, slots) { KnowledgeGraph::InsertBloodTestResult.new(**common.merge(slots)) },
        writer: lambda do |engine, intent, provenance|
          engine.insert(
            "blood_tests",
            compact(
              observed_at: intent.observed_at, marker: intent.marker,
              value: intent.value, unit: intent.unit || "unspecified"
            ),
            provenance
          )
        end
      )
      registry.register(
        intent: "dataset.body_measurement", dataset: "body_measurements",
        intent_class: KnowledgeGraph::InsertBodyMeasurement,
        builder: ->(common, slots) { KnowledgeGraph::InsertBodyMeasurement.new(**common.merge(slots)) },
        writer: lambda do |engine, intent, provenance|
          engine.insert(
            "body_measurements",
            {
              observed_at: intent.observed_at, measurement: intent.measurement,
              value: intent.value, unit: intent.unit
            },
            provenance
          )
        end
      )
      registry.register(
        intent: "dataset.expense", dataset: "expenses",
        intent_class: KnowledgeGraph::InsertExpense,
        builder: ->(common, slots) { KnowledgeGraph::InsertExpense.new(**common.merge(slots)) },
        writer: lambda do |engine, intent, provenance|
          engine.insert(
            "expenses",
            compact(
              occurred_on: intent.occurred_on, category: intent.category,
              amount: intent.amount, currency: intent.currency, merchant: intent.merchant
            ),
            provenance
          )
        end
      )
      registry
    end

    def compact(values)
      values.reject { |_key, value| value.nil? }
    end
  end

  class DatasetProposalBuilder
    PIPELINE_VERSION = "dataset-routing-v1".freeze
    PROMPT_VERSION = "intent-classifier-v1".freeze

    def initialize(vault_root:, proposal_store:, classifier:, event_bus: nil, clock: nil,
                   routing_registry: StructuredDataset.routing_registry)
      @vault_root = vault_root
      @proposal_store = proposal_store
      @classifier = classifier
      @event_bus = event_bus
      @clock = clock || -> { Time.now }
      @routing_registry = routing_registry
    end

    def create(arguments)
      document = source_document(arguments)
      classification = @classifier.classify(document.content, "captured_at" => document.captured_at)
      unless classification && classification.route == "dataset"
        raise InvalidRow, "message is not a structured Dataset observation"
      end
      if classification.slots["clarification_required"]
        return {
          "status" => "clarification_required", "classification" => classification.to_h,
          "question" => "Which Dataset schema should receive these structured rows?",
          "executable" => false, "approval_required" => true, "planned_intent_count" => 0
        }
      end

      proposal_id = KnowledgeExtraction::Support.stable_id(
        "proposal", document.source_id, classification.intent,
        KnowledgeExtraction::Support.canonical_json(classification.slots),
        dataset_state_signature(classification.intent)
      )
      route = @routing_registry.fetch(classification.intent)
      intent = build_intent(route, classification, document, proposal_id, arguments)
      evidence = KnowledgeExtraction::EvidenceSpan.new(
        source_id: document.source_id, start_offset: 0,
        end_offset: [document.content.length, 2_000].min,
        excerpt: document.content[0...[document.content.length, 2_000].min]
      )
      subject = KnowledgeExtraction::EntityMention.new(
        entity_type: "person", display_name: "Dataset owner", evidence: [evidence]
      )
      fact = KnowledgeExtraction::ExtractedFact.new(
        fact_type: "dataset_observation", subject: subject,
        predicate: route.dataset,
        object: KnowledgeExtraction::ScalarValue.new(
          value: classification.slots, value_type: "json",
          original_expression: evidence.excerpt, normalized_value: classification.slots,
          normalization_confidence: classification.confidence
        ),
        confidence: classification.confidence, evidence: [evidence],
        extraction_method: "intent_classifier"
      )
      dataset_id = KnowledgeExtraction::Support.deterministic_ulid(
        "dataset", document.captured_at || @clock.call, document.source_id, route.dataset
      )
      evolution = AutonomousRegistry.new(
        vault_root: @vault_root, engine: evolution_engine, clock: @clock
      ).plan(
        dataset: route.dataset, values: route.row_builder.call(intent),
        source: arguments["origin_source"] || document.source_type,
        proposal_id: proposal_id, dataset_id: dataset_id
      )
      provenance = {
        source_id: document.source_id, source_type: document.source_type,
        captured_at: document.captured_at&.iso8601
      }
      prerequisite = evolution.prerequisite? ? KnowledgeExtraction::PlannedIntent.new(
        planned_intent_id: KnowledgeExtraction::Support.stable_id(
          "planned", proposal_id, evolution.intent.intent_type
        ),
        intent: evolution.intent, fact_ids: [fact.fact_id], evidence_ids: [evidence.evidence_id],
        planning_confidence: classification.confidence, risk: "medium",
        approval_requirement: "human_review", blocked_reasons: [], provenance: provenance
      ) : nil
      planned = KnowledgeExtraction::PlannedIntent.new(
        planned_intent_id: KnowledgeExtraction::Support.stable_id(
          "planned", proposal_id, intent.intent_type
        ),
        intent: intent, fact_ids: [fact.fact_id], evidence_ids: [evidence.evidence_id],
        planning_confidence: classification.confidence, risk: "medium",
        approval_requirement: "human_review", blocked_reasons: [],
        dependencies: prerequisite ? [prerequisite.planned_intent_id] : [], provenance: provenance
      )
      planned_intents = [prerequisite, planned].compact
      warnings = evolution_warning(evolution)
      proposal = KnowledgeExtraction::ExtractionProposal.new(
        proposal_id: proposal_id, source: document,
        summary: proposal_summary(route.dataset, evolution),
        facts: [fact], entity_mentions: [subject], resolution_decisions: [],
        planned_intents: planned_intents, warnings: warnings, conflicts: [],
        required_approvals: {
          total: planned_intents.length, blocked: 0,
          by_risk: { low: 0, medium: planned_intents.length, high: 0 }
        },
        rejected_items: [],
        model_metadata: {
          "provider" => "intent-classifier", "intent" => classification.intent,
          "confidence" => classification.confidence,
          "dataset_evolution" => evolution.to_h
        },
        prompt_version: PROMPT_VERSION, pipeline_version: PIPELINE_VERSION,
        created_at: document.captured_at || @clock.call, status: "awaiting_approval",
        ingestion_state: @proposal_store.classify_source(document)
      )
      @proposal_store.save(proposal)
      @proposal_store.record_source(document, proposal.proposal_id)
      KnowledgeExtraction::ProposalValidator.new.validate!(@proposal_store.load(proposal.proposal_id))
      publish_proposal(proposal, classification, arguments)
      {
        "status" => proposal.status, "proposal_id" => proposal.proposal_id,
        "observation_id" => arguments["observation_id"],
        "classification" => classification.to_h,
        "planned_intent_count" => proposal.planned_intents.length,
        "approval_required" => true, "executable" => false,
        "warnings" => proposal.warnings, "dataset_evolution" => evolution.to_h
      }.reject { |_key, value| value.nil? }
    end

    private

    def source_document(arguments)
      envelope_metadata = {
        "observation_id" => arguments["observation_id"],
        "observation_source" => arguments["origin_source"],
        "conversation_id" => arguments["conversation_id"],
        "message_id" => arguments["message_id"], "sender" => arguments["sender"],
        "sensitivity" => arguments.fetch("sensitivity", "private")
      }.reject { |_key, value| value.nil? }
      KnowledgeExtraction::SourceDocument.new(
        source_type: arguments.fetch("source_type"), content: arguments.fetch("content"),
        language: arguments.fetch("language", "und"), captured_at: arguments["captured_at"],
        external_id: arguments["external_id"], source_uri: arguments["source_uri"],
        title: arguments["title"], author: arguments["sender"], metadata: envelope_metadata
      )
    end

    def build_intent(route, classification, document, proposal_id, arguments)
      common = {
        source: arguments["origin_source"] || document.source_type,
        observation_id: arguments["observation_id"] || document.source_id,
        proposal_id: proposal_id,
        intent_id: KnowledgeExtraction::Support.stable_id(
          "intent", document.source_id, classification.intent,
          KnowledgeExtraction::Support.canonical_json(classification.slots)
        )
      }
      slots = classification.slots.transform_keys(&:to_sym)
      route.builder.call(common, slots)
    end

    def dataset_state_signature(intent_name)
      route = @routing_registry.fetch(intent_name)
      description = evolution_engine.describe(route.dataset)
      KnowledgeExtraction::Support.canonical_json(
        "dataset_id" => description.fetch("dataset_id"),
        "schema_version" => description.fetch("schema_version"),
        "columns" => description.fetch("columns")
      )
    rescue DatasetNotFound
      "missing:#{@routing_registry.fetch(intent_name).dataset}"
    end

    def evolution_engine
      @evolution_engine ||= Engine.new(vault_root: @vault_root, clock: @clock)
    end

    def evolution_warning(evolution)
      case evolution.kind
      when "create"
        ["Dataset #{evolution.dataset} is not registered; approval will create it before the observation is written."]
      when "schema_upgrade"
        ["Dataset #{evolution.dataset} needs additive columns #{evolution.added_columns.join(', ')}; approval will upgrade it before retrying the observation."]
      else
        []
      end
    end

    def proposal_summary(dataset, evolution)
      case evolution.kind
      when "create"
        "Classified one structured observation and planned automatic registration of #{dataset}."
      when "schema_upgrade"
        "Classified one structured observation and planned an additive schema upgrade for #{dataset}."
      else
        "Classified one structured observation for #{dataset}."
      end
    end

    def publish_proposal(proposal, classification, arguments)
      return unless @event_bus

      correlation_id = arguments["observation_id"] || proposal.proposal_id
      @event_bus.publish(
        type: "ProposalCreated", source: "dataset-intent-classifier",
        payload: {
          "observation_id" => arguments["observation_id"],
          "proposal_id" => proposal.proposal_id, "status" => proposal.status,
          "intent" => classification.intent, "executable" => false
        }.reject { |_key, value| value.nil? },
        correlation_id: correlation_id
      )
    rescue KnowledgeOrchestration::Error
      nil
    end
  end

  class IntentHandler
    def initialize(dataset_engine:, proposal_id:, approval: nil,
                   routing_registry: StructuredDataset.routing_registry)
      @dataset_engine = dataset_engine
      @proposal_id = proposal_id
      @approval = approval
      @routing_registry = routing_registry
    end

    def attach(engine)
      supported.each { |intent_class| engine.register(intent_class, method(:execute)) }
      engine
    end

    def self.supports?(intent)
      intent.is_a?(KnowledgeGraph::InsertDatasetRow) || lifecycle_intent?(intent) ||
        StructuredDataset.routing_registry.intent_classes.any? { |intent_class| intent.is_a?(intent_class) }
    end

    def self.lifecycle_intent?(intent)
      intent.is_a?(KnowledgeGraph::CreateDataset) ||
        intent.is_a?(KnowledgeGraph::UpgradeDatasetSchema)
    end

    def execute(intent, context = nil)
      unless @approval && @approval["approval_id"] && @approval["actor_id"]
        raise KnowledgeGraph::ApprovalRequired, "Dataset Intents require an exact approved proposal"
      end

      raise KnowledgeGraph::TransactionError, "Dataset Intent execution requires an Engine context" unless context

      return execute_lifecycle(intent, context) if self.class.lifecycle_intent?(intent)

      dataset = dataset_for(intent)
      dataset_id = @dataset_engine.describe(dataset).fetch("dataset_id")
      context.defer { execute_row(intent, dataset, dataset_id) }
      KnowledgeGraph::Result.new(intent_type: intent.intent_type, entity_ids: [dataset_id])
    end

    private

    def execute_lifecycle(intent, context)
      dataset_id = if intent.is_a?(KnowledgeGraph::CreateDataset)
                     intent.dataset_id
                   else
                     @dataset_engine.describe(intent.dataset).fetch("dataset_id")
                   end
      context.defer { execute_lifecycle_change(intent, dataset_id) }
      KnowledgeGraph::Result.new(intent_type: intent.intent_type, entity_ids: [dataset_id])
    end

    def execute_lifecycle_change(intent, dataset_id)
      result = if intent.is_a?(KnowledgeGraph::CreateDataset)
                 create_dataset(intent)
               else
                 upgrade_schema(intent)
               end
      KnowledgeGraph::Result.new(
        intent_type: intent.intent_type, entity_ids: [dataset_id],
        replayed: result.fetch("replayed", false),
        value: {
          "dataset_id" => dataset_id, "schema_version" => result["schema_version"],
          "dataset_activity_id" => result["dataset_activity_id"],
          "added_columns" => intent.respond_to?(:added_columns) ? intent.added_columns : nil
        }.reject { |_key, value| value.nil? }
      )
    end

    def create_dataset(intent)
      @dataset_engine.create(
        intent.dataset, schema: intent.schema, owner_id: intent.owner_id,
        dataset_id: intent.dataset_id, provenance: provenance(intent)
      )
    rescue DatasetConflict
      existing = @dataset_engine.describe(intent.dataset)
      unless existing.fetch("dataset_id") == intent.dataset_id &&
             existing.fetch("columns") == Definition.from_h(intent.schema).columns.map(&:to_h)
        raise
      end

      existing.merge("replayed" => true)
    end

    def upgrade_schema(intent)
      current = @dataset_engine.describe(intent.dataset)
      target = Definition.from_h(intent.schema)
      if current.fetch("schema_version").to_i > intent.from_version.to_i
        return current.merge("replayed" => true) if current.fetch("columns") == target.columns.map(&:to_h)

        raise MigrationError, "Dataset schema changed after this proposal was created"
      end
      unless current.fetch("schema_version").to_i == intent.from_version.to_i
        raise MigrationError, "Dataset schema version does not match the approved proposal"
      end

      @dataset_engine.migrate(intent.dataset, intent.schema, provenance(intent))
    end

    def execute_row(intent, dataset, dataset_id)
      row, dataset = if intent.is_a?(KnowledgeGraph::InsertDatasetRow)
                       [@dataset_engine.insert(intent.dataset, intent.values, provenance(intent)), intent.dataset]
                     else
                       route = @routing_registry.for_intent(intent)
                       [route.writer.call(@dataset_engine, intent, provenance(intent)), route.dataset]
                     end
      KnowledgeGraph::Result.new(
        intent_type: intent.intent_type, entity_ids: [dataset_id], replayed: row.fetch("replayed", false),
        value: {
          "dataset_id" => dataset_id, "row_id" => row.fetch("row_id"),
          "dataset_activity_id" => row["dataset_activity_id"]
        }.reject { |_key, value| value.nil? }
      )
    end

    def dataset_for(intent)
      return intent.dataset if intent.is_a?(KnowledgeGraph::InsertDatasetRow)

      @routing_registry.for_intent(intent).dataset
    end

    def supported
      [
        KnowledgeGraph::InsertDatasetRow, KnowledgeGraph::CreateDataset,
        KnowledgeGraph::UpgradeDatasetSchema, *@routing_registry.intent_classes
      ].uniq
    end

    def provenance(intent)
      {
        source: intent.source,
        observation_id: intent.respond_to?(:observation_id) ? intent.observation_id : nil,
        proposal_id: @proposal_id || (intent.respond_to?(:proposal_id) && intent.proposal_id),
        approval_id: @approval && @approval["approval_id"],
        created_by: @approval && @approval["actor_id"] || "proposal-engine",
        intent_id: intent.intent_id
      }.reject { |_key, value| value.nil? }
    end
  end
end

StructuredDataset::CoreRoutes.register
StructuredDataset::IntentClassifierPlugin.register
