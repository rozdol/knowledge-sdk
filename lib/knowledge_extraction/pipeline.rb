# frozen_string_literal: true

module KnowledgeExtraction
  class KnowledgeExtractionPipeline
    attr_reader :configuration

    def initialize(graph_reader:, provider: DeterministicExtractionProvider.new,
                   configuration: Configuration.new, proposal_store: nil,
                   logger: StructuredLogger.new, clock: nil)
      @graph_reader = graph_reader
      @provider = provider
      @configuration = configuration
      @proposal_store = proposal_store
      @logger = logger
      @clock = clock || -> { Time.now }
      @normalizer = SourceNormalizer.new(configuration: configuration)
      @validator = StructuredOutputValidator.new(configuration: configuration)
      @resolver = ConservativeEntityResolver.new(graph_reader: graph_reader, configuration: configuration)
      @planner = IntentPlanner.new(graph_reader: graph_reader, configuration: configuration)
      @last_document = nil
      @last_extraction = nil
    end

    def process(source, source_type: nil, persist: false, **metadata)
      metrics = StageMetrics.new
      document = metrics.measure("normalization") { normalize(source, source_type: source_type, **metadata) }
      ingestion_state = @proposal_store ? @proposal_store.classify_source(document) : "new"
      raw = metrics.measure("extraction") { extract(document) }
      validated = metrics.measure("validation") { validate_facts(raw, document: document) }
      resolved = metrics.measure("resolution") { resolve_entities(validated, document: document) }
      planning = metrics.measure("planning") { plan_intents(resolved) }
      metrics.merge!(
        source_type: document.source_type, provider: raw.provider_name, model: raw.model_name,
        prompt_version: raw.prompt_version, extracted_facts: raw.payload.fetch("facts", []).length,
        accepted_facts: validated.facts.length, rejected_facts: validated.rejected_items.length,
        ambiguous_entities: resolved.decisions.count { |decision| %w[ambiguous conflict].include?(decision.outcome) },
        proposed_intents: planning.planned_intents.length,
        blocked_intents: planning.planned_intents.count(&:blocked?), token_usage: raw.token_usage
      )
      deterministic_metrics = metrics.to_h.reject { |key, _value| key.end_with?("_duration_ms") }
      proposal = build_proposal(document, validated, resolved, planning, ingestion_state, deterministic_metrics)
      if persist
        raise PlanningFailure, "persist requested without a ProposalStore" unless @proposal_store

        @proposal_store.save(proposal) unless ingestion_state == "exact_duplicate"
        @proposal_store.record_source(document, proposal.proposal_id)
      end
      @logger.emit("extraction_pipeline_complete", log_attributes(proposal).merge(metrics.to_h))
      proposal
    rescue StandardError => error
      @logger.emit(
        "extraction_pipeline_failed",
        error_class: error.class.name, error: error.message,
        source_id: @last_document&.source_id, provider: @configuration.provider_name
      )
      raise
    end

    def normalize(source, source_type: nil, **metadata)
      @last_document = @normalizer.normalize(source, source_type: source_type, **metadata)
    end

    def extract(document)
      @last_document = document
      @provider.extract(
        document,
        { configuration: configuration, graph_context: [], self_entity: @graph_reader.self_entity }
      )
    rescue KnowledgeExtraction::Error
      raise
    rescue StandardError => error
      raise ProviderFailure, "provider extraction failed: #{error.class}: #{error.message}"
    end

    def validate_facts(raw, document: nil)
      source = document || @last_document
      raise FactValidationFailure, "document is required for evidence validation" unless source

      @last_extraction = @validator.validate(raw, source)
    end

    def resolve_entities(extraction, document: nil)
      source = document || @last_document
      raise EntityResolutionConflict, "document is required for resolution" unless source

      ResolvedExtraction.new(
        document: source, extraction: extraction,
        decisions: @resolver.resolve(extraction.mentions)
      )
    end

    def plan_intents(resolved)
      @planner.plan(
        document: resolved.document, extraction: resolved.extraction,
        resolutions: resolved.decisions
      )
    end

    private

    def build_proposal(document, validated, resolved, planning, ingestion_state, metrics)
      conflicts = resolved.decisions.select { |decision| decision.outcome == "conflict" }
                          .map(&:explanation)
      ambiguous = resolved.decisions.any? { |decision| %w[ambiguous conflict].include?(decision.outcome) }
      ready = planning.planned_intents.reject(&:blocked?)
      status = if ambiguous || planning.planned_intents.any?(&:blocked?)
                 "resolution_required"
               elsif ready.empty?
                 "partially_rejected"
               elsif ready.any? { |item| item.approval_requirement != "none" }
                 "awaiting_approval"
               else
                 "planned"
               end
      approvals = {
        total: ready.count { |item| item.approval_requirement != "none" },
        blocked: planning.planned_intents.count(&:blocked?),
        by_risk: %w[low medium high].to_h do |risk|
          [risk, ready.count { |item| item.risk == risk }]
        end
      }
      rejected = validated.rejected_items + planning.rejected_items
      warnings = validated.warnings + planning.warnings
      warnings << "Source is classified as #{ingestion_state}; it was not silently discarded" unless ingestion_state == "new"
      proposal_id = Support.stable_id(
        "proposal", document.source_id, document.content_hash,
        configuration.pipeline_version, configuration.prompt_version,
        validated.provider_metadata[:provider], validated.provider_metadata[:model]
      )
      ExtractionProposal.new(
        proposal_id: proposal_id, source: document, summary: validated.summary,
        facts: validated.facts, entity_mentions: validated.mentions,
        resolution_decisions: resolved.decisions, planned_intents: planning.planned_intents,
        warnings: warnings, conflicts: conflicts, required_approvals: approvals,
        rejected_items: rejected, model_metadata: validated.provider_metadata,
        prompt_version: configuration.prompt_version, pipeline_version: configuration.pipeline_version,
        created_at: document.captured_at || Time.at(0).utc, status: status,
        ingestion_state: ingestion_state, metrics: metrics
      )
    end

    def log_attributes(proposal)
      {
        proposal_id: proposal.proposal_id, source_id: proposal.source.source_id,
        source_type: proposal.source.source_type, provider: proposal.model_metadata[:provider],
        model: proposal.model_metadata[:model], prompt_version: proposal.prompt_version,
        facts: proposal.facts.length, proposed_intents: proposal.planned_intents.length,
        blocked_intents: proposal.planned_intents.count(&:blocked?), status: proposal.status
      }
    end
  end
end
