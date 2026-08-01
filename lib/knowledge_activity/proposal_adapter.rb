# frozen_string_literal: true

require "digest"
require "json"
require "time"

module KnowledgeActivity
  class ProposalAdapter
    PIPELINE_VERSION = "knowledge-activity-10.0.0"

    def initialize(vault_root:, audits:, clock: nil, event_bus: nil, id_generator: nil)
      @vault_root = File.expand_path(vault_root.to_s)
      @clock = clock || -> { Time.now }
      @event_bus = event_bus
      @id_generator = id_generator || KnowledgeGraph::IdGenerator.new(clock: @clock)
      @planner = ReversalPlanner.new(vault_root: @vault_root, audits: audits)
      @store = KnowledgeExtraction::ProposalStore.new(vault_root: @vault_root, clock: @clock)
    end

    def available?(activity, operation:)
      @planner.available?(activity, operation: operation)
    end

    def create(activity, operation:)
      operation = operation.to_s
      intents = @planner.intents_for(activity, operation: operation)
      raise ReversalUnavailable, "#{operation} produced no reverse Intents" if intents.empty?

      proposal = build(activity, operation, intents)
      @store.save(proposal)
      publish_created(activity, proposal, operation)
      proposal
    end

    private

    def build(activity, operation, intents)
      proposal_id = @id_generator.generate("proposal")
      source_id = KnowledgeOrchestration::Stable.id("source", proposal_id, activity.id, operation)
      excerpt = exact_audit_evidence(activity)
      evidence_id = KnowledgeOrchestration::Stable.id("evidence", source_id, excerpt)
      fact_id = KnowledgeOrchestration::Stable.id("fact", proposal_id, activity.id)
      planned = intents.each_with_index.map do |intent, index|
        planned_intent_id = KnowledgeOrchestration::Stable.id("planned-intent", proposal_id, index, intent)
        {
          "planned_intent_id" => planned_intent_id,
          "intent" => AgentPlatform::Value.canonical(intent),
          "idempotency_key" => Digest::SHA256.hexdigest(AgentPlatform::Value.canonical_json(intent)),
          "fact_ids" => [fact_id], "evidence_ids" => [evidence_id],
          "planning_confidence" => 1.0, "risk" => risk_for(intent.fetch("type")),
          "approval_requirement" => "human_review",
          "dependencies" => index.zero? ? [] : [KnowledgeOrchestration::Stable.id(
            "planned-intent", proposal_id, index - 1, intents[index - 1]
          )],
          "blocked_reasons" => [],
          "provenance" => {
            "source_id" => source_id, "activity_id" => activity.id,
            "originating_audit_id" => activity.audit.fetch("id"),
            "originating_proposal_id" => activity.proposal,
            "operation" => operation, "derived" => true,
            "fact_confidence" => 1.0, "resolution_confidence" => 1.0,
            "planning_confidence" => 1.0
          }.reject { |_key, value| value.nil? },
          "local_references" => {}, "safe_dependency_group" => proposal_id
        }
      end
      fact = {
        "fact_id" => fact_id, "finding_id" => activity.id,
        "fact_type" => "knowledge_activity_#{operation}", "confidence" => 1.0,
        "resolution_confidence" => 1.0, "planning_confidence" => 1.0,
        "status" => "asserted", "subject" => activity.id,
        "predicate" => "#{operation}_activity", "object" => activity.audit.fetch("id"),
        "evidence" => [{
          "evidence_id" => evidence_id, "source_id" => source_id,
          "record_id" => activity.audit.fetch("id"), "field" => "audit_receipt",
          "role" => "supporting", "value" => activity.audit.fetch("fingerprint"),
          "quote" => excerpt, "excerpt" => excerpt
        }],
        "explanation" => "The immutable audit receipt is the exact basis for this #{operation} proposal."
      }
      now = @clock.call.iso8601
      payload = {
        "proposal_id" => proposal_id,
        "source" => {
          "source_id" => source_id, "source_type" => "text", "language" => "und",
          "captured_at" => now, "title" => "Knowledge Activity #{operation}: #{activity.id}",
          "metadata" => {
            "derived" => true, "knowledge_activity" => true, "operation" => operation,
            "activity_id" => activity.id, "originating_audit_id" => activity.audit.fetch("id"),
            "originating_proposal_id" => activity.proposal, "event_ids" => activity.events,
            "originating_source" => activity.source,
            "sensitivity" => activity.privacy == "redacted" ? "restricted" : "private"
          }.reject { |_key, value| value.nil? },
          "content_hash" => Digest::SHA256.hexdigest(excerpt)
        },
        "summary" => proposal_summary(activity, operation),
        "facts" => [fact], "entity_mentions" => [], "resolution_candidates" => [],
        "resolution_decisions" => [], "planned_intents" => planned,
        "warnings" => [], "conflicts" => [],
        "required_approvals" => planned.map do |item|
          { "planned_intent_id" => item.fetch("planned_intent_id"), "requirement" => "human_review" }
        end,
        "rejected_items" => [],
        "model_metadata" => { "provider" => "none", "deterministic" => true },
        "prompt_version" => "none", "pipeline_version" => PIPELINE_VERSION,
        "created_at" => now, "status" => "awaiting_approval", "ingestion_state" => "new",
        "metrics" => { "activity_count" => 1, "intent_count" => planned.length }
      }
      KnowledgeExtraction::ProposalValidator.new.validate!(payload)
      AgentPlatform::Value.immutable(payload)
    end

    def exact_audit_evidence(activity)
      audit = AgentPlatform::Value.mutable(activity.audit)
      JSON.generate(
        "id" => audit.fetch("id"), "timestamp" => audit.fetch("timestamp"),
        "fingerprint" => audit.fetch("fingerprint"), "intent" => audit.fetch("intent"),
        "entity_ids" => audit.fetch("entity_ids"), "result" => audit.fetch("result")
      )
    end

    def proposal_summary(activity, operation)
      verb = operation == "undo" ? "Undo" : "Restore"
      "#{verb} activity #{activity.id}: #{activity.summary}"
    end

    def risk_for(type)
      return "high" if %w[ArchiveEntity RemoveRelationship ReplaceRelationship RenameEntity].include?(type)

      "medium"
    end

    def publish_created(activity, proposal, operation)
      return unless @event_bus

      @event_bus.publish(
        type: "ProposalCreated", source: "knowledge-activity",
        payload: {
          "proposal_id" => proposal.fetch("proposal_id"), "status" => proposal.fetch("status"),
          "activity_id" => activity.id, "operation" => operation, "executable" => false
        },
        causation_id: activity.events.first
      )
    end
  end
end
