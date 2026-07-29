# frozen_string_literal: true

module KnowledgeExtraction
  class ExtractionProposal < ImmutableModel
    STATUSES = %w[
      received normalized extracted validated resolution_required planned awaiting_approval approved submitted
      executed partially_rejected failed
    ].freeze
    INGESTION_STATES = %w[new exact_duplicate exact_content_duplicate revision].freeze

    attr_reader :proposal_id, :source, :summary, :facts, :entity_mentions,
                :resolution_candidates, :resolution_decisions, :planned_intents,
                :warnings, :conflicts, :required_approvals, :rejected_items,
                :model_metadata, :prompt_version, :pipeline_version, :created_at,
                :status, :ingestion_state, :metrics

    def initialize(proposal_id:, source:, summary:, facts:, entity_mentions:,
                   resolution_decisions:, planned_intents:, warnings:, conflicts:,
                   required_approvals:, rejected_items:, model_metadata:, prompt_version:,
                   pipeline_version:, created_at:, status:, ingestion_state: "new", metrics: {})
      @proposal_id = required_string(proposal_id, "proposal_id", maximum: 200)
      raise ArgumentError, "source must be a SourceDocument" unless source.is_a?(SourceDocument)
      @source = source
      @summary = summary.to_s.freeze
      @facts = immutable(facts)
      @entity_mentions = immutable(entity_mentions)
      @resolution_decisions = immutable(resolution_decisions)
      @resolution_candidates = immutable(resolution_decisions.flat_map(&:candidates))
      @planned_intents = immutable(planned_intents)
      @warnings = immutable(Array(warnings).map(&:to_s).uniq)
      @conflicts = immutable(Array(conflicts).map(&:to_s).uniq)
      @required_approvals = immutable(required_approvals)
      @rejected_items = immutable(rejected_items)
      @model_metadata = immutable(model_metadata)
      @prompt_version = required_string(prompt_version, "prompt_version", maximum: 100)
      @pipeline_version = required_string(pipeline_version, "pipeline_version", maximum: 100)
      @created_at = Support.parse_time(created_at, field: "created_at")
      @status = status.to_s.freeze
      raise ArgumentError, "invalid proposal status #{@status.inspect}" unless STATUSES.include?(@status)
      @ingestion_state = ingestion_state.to_s.freeze
      unless INGESTION_STATES.include?(@ingestion_state)
        raise ArgumentError, "invalid ingestion_state #{@ingestion_state.inspect}"
      end
      @metrics = immutable(metrics)
      validate_traceability!
      freeze
    end

    def canonical_json
      JSON.pretty_generate(Support.canonical(to_h)) + "\n"
    end

    def to_h
      {
        proposal_id: proposal_id, source: source.metadata_only, summary: summary,
        facts: facts.map(&:to_h), entity_mentions: entity_mentions.map(&:to_h),
        resolution_candidates: resolution_candidates.map(&:to_h),
        resolution_decisions: resolution_decisions.map(&:to_h),
        planned_intents: planned_intents.map(&:to_h), warnings: warnings,
        conflicts: conflicts, required_approvals: required_approvals,
        rejected_items: rejected_items.map(&:to_h), model_metadata: model_metadata,
        prompt_version: prompt_version, pipeline_version: pipeline_version,
        created_at: created_at.iso8601, status: status,
        ingestion_state: ingestion_state, metrics: metrics
      }
    end

    private

    def validate_traceability!
      fact_ids = facts.map(&:fact_id)
      evidence_ids = facts.flat_map(&:evidence).map(&:evidence_id)
      planned_intents.each do |planned|
        unless (planned.fact_ids - fact_ids).empty?
          raise PlanningFailure, "planned Intent references unknown facts"
        end
        unless (planned.evidence_ids - evidence_ids).empty?
          raise PlanningFailure, "planned Intent references unknown evidence"
        end
        provenance = planned.provenance
        raise PlanningFailure, "planned Intent source provenance mismatch" unless provenance[:source_id] == source.source_id
      end
    end
  end

  class ResolvedExtraction < ImmutableModel
    attr_reader :document, :extraction, :decisions

    def initialize(document:, extraction:, decisions:)
      @document = document
      @extraction = extraction
      @decisions = immutable(decisions)
      freeze
    end

    def to_h
      { document: document.to_h, extraction: extraction.to_h, decisions: decisions.map(&:to_h) }
    end
  end
end
