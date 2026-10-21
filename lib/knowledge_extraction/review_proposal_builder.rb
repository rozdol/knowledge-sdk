# frozen_string_literal: true

require "digest"

module KnowledgeExtraction
  class ReviewProposalBuilder
    def initialize(vault_root:, proposal_store: nil, event_bus: nil, clock: nil, domain: "capture")
      @domain = domain.to_s
      @vault_root = vault_root
      @clock = clock || -> { Time.now }
      @store = proposal_store || KnowledgeExtraction::ProposalStore.new(vault_root: vault_root, clock: @clock)
      @event_bus = event_bus
    end

    def evidence_id(document, role: @domain)
      KnowledgeExtraction::Support.stable_id(
        "evidence", document.source_id, document.content_hash, role
      )
    end

    def persist(document:, planned_intents:, summary:, model_metadata:, confidence:,
                evidence_documents: [])
      proposal_id = KnowledgeExtraction::Support.stable_id(
        "proposal", document.source_id, summary,
        KnowledgeExtraction::Support.canonical_json(
          planned_intents.map { |spec| spec.fetch(:intent).to_h }
        )
      )
      sources = [{ document: document, role: @domain }] + Array(evidence_documents)
      evidence = sources.map do |spec|
        source_document = spec.fetch(:document)
        excerpt = source_document.content[0, 2_000]
        {
          "evidence_id" => evidence_id(source_document, role: spec.fetch(:role)),
          "source_id" => source_document.source_id, "start_offset" => 0,
          "end_offset" => excerpt.length, "excerpt" => excerpt
        }
      end
      evidence_ids = evidence.map { |item| item.fetch("evidence_id") }
      fact_id = KnowledgeExtraction::Support.stable_id("fact", document.source_id, @domain)
      planned = planned_intents.map do |spec|
        KnowledgeExtraction::PlannedIntent.new(
          planned_intent_id: spec.fetch(:planned_intent_id), intent: spec.fetch(:intent),
          fact_ids: [fact_id], evidence_ids: evidence_ids,
          planning_confidence: confidence, risk: spec.fetch(:risk, "medium"),
          approval_requirement: "human_review", dependencies: spec.fetch(:dependencies, []),
          blocked_reasons: [], provenance: {
            source_id: document.source_id, source_type: document.source_type,
            captured_at: document.captured_at&.iso8601
          }
        )
      end
      proposal = {
        "proposal_id" => proposal_id, "source" => stringify(document.metadata_only),
        "summary" => summary,
        "facts" => [{
          "fact_id" => fact_id, "fact_type" => @domain, "confidence" => confidence,
          "evidence" => evidence
        }],
        "entity_mentions" => [], "resolution_candidates" => [], "resolution_decisions" => [],
        "planned_intents" => planned.map { |item| stringify(item.to_h) },
        "warnings" => [], "conflicts" => [],
        "required_approvals" => {
          "total" => planned.length, "blocked" => 0,
          "by_risk" => {
            "low" => planned.count { |item| item.risk == "low" },
            "medium" => planned.count { |item| item.risk == "medium" },
            "high" => planned.count { |item| item.risk == "high" }
          }
        },
        "rejected_items" => [], "model_metadata" => model_metadata,
        "prompt_version" => @domain == "capture" ? "knowledge-capture-v2" : "#{@domain}-review-v1", "pipeline_version" => KnowledgeSDK::VERSION,
        "created_at" => (@clock.call).iso8601, "status" => "awaiting_approval",
        "ingestion_state" => @store.classify_source(document), "metrics" => {
          "proposed_intents" => planned.length, "capture_evidence" => evidence.length
        }
      }
      @store.save(proposal)
      sources.each { |spec| @store.record_source(spec.fetch(:document), proposal_id) }
      KnowledgeExtraction::ProposalValidator.new.validate!(@store.load(proposal_id))
      publish(proposal_id, planned, document)
      [proposal, planned]
    end

    private

    def stringify(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = stringify(item) }
      when Array then value.map { |item| stringify(item) }
      else value
      end
    end

    def publish(proposal_id, planned, document)
      return unless @event_bus

      @event_bus.publish(
        type: "ProposalCreated", source: "knowledge-#{@domain}",
        payload: {
          "proposal_id" => proposal_id, "status" => "awaiting_approval",
          "planned_intent_count" => planned.length, "source_id" => document.source_id
        }, correlation_id: proposal_id
      )
    end
  end

end
