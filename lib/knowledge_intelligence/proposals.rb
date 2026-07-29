# frozen_string_literal: true

require "digest"

module KnowledgeIntelligence
  class ProposalAdapter
    PIPELINE_VERSION = "knowledge-intelligence-6.0.0"

    def build(run_result, finding_ids: nil)
      selected = run_result.findings.select { |finding| !finding.intent_proposals.empty? }
      requested = Array(finding_ids).map(&:to_s)
      selected = selected.select { |finding| requested.include?(finding.finding_id) } unless requested.empty?
      raise Error, "no Intent proposals matched the selected findings" if selected.empty?

      entries = {}
      selected.each do |finding|
        finding.intent_proposals.each do |proposal|
          current = entries[proposal.planned_intent_id]
          if current.nil? || finding.finding_id == proposal.finding_id
            entries[proposal.planned_intent_id] = [finding, proposal]
          end
        end
      end
      entries = entries.values.sort_by { |_finding, proposal| proposal.planned_intent_id }
      selected = entries.map(&:first).uniq(&:finding_id)

      source_id = Stable.id("source", run_result.snapshot_digest, run_result.as_of)
      facts = selected.map { |finding| fact_for(finding) }
      intents = entries.map do |finding, proposal|
        fact = facts.find { |item| item["finding_id"] == finding.finding_id }
        planned_intent(proposal, fact, source_id)
      end
      proposal_id = Stable.id("proposal", source_id, intents.map { |item| item["planned_intent_id"] })
      content_hash = Digest::SHA256.hexdigest(Stable.json(facts))
      payload = {
        "proposal_id" => proposal_id,
        "source" => {
          "source_id" => source_id, "source_type" => "text", "language" => "und",
          "captured_at" => "#{run_result.as_of}T00:00:00Z",
          "title" => "Knowledge Intelligence recommendations",
          "metadata" => { "snapshot_digest" => run_result.snapshot_digest, "derived" => true },
          "content_hash" => content_hash
        },
        "summary" => "#{intents.length} reviewable Intent proposal(s) derived deterministically from graph findings.",
        "facts" => facts, "entity_mentions" => [], "resolution_candidates" => [],
        "resolution_decisions" => [], "planned_intents" => intents,
        "warnings" => [], "conflicts" => [],
        "required_approvals" => intents.map do |item|
          { "planned_intent_id" => item["planned_intent_id"], "requirement" => item["approval_requirement"] }
        end,
        "rejected_items" => [], "model_metadata" => { "provider" => "none", "deterministic" => true },
        "prompt_version" => "none", "pipeline_version" => PIPELINE_VERSION,
        "created_at" => "#{run_result.as_of}T00:00:00Z", "status" => "awaiting_approval",
        "ingestion_state" => "new", "metrics" => { "finding_count" => selected.length, "intent_count" => intents.length }
      }
      KnowledgeExtraction::ProposalValidator.new.validate!(payload)
      Immutable.copy(payload)
    end

    def persist(payload, vault_root:)
      KnowledgeExtraction::ProposalStore.new(vault_root: vault_root).save(payload)
    end

    private

    def fact_for(finding)
      evidence = finding.evidence.map do |item|
        item.to_h.transform_keys(&:to_s).merge("quote" => item.value.to_s)
      end
      {
        "fact_id" => Stable.id("fact", finding.finding_id),
        "finding_id" => finding.finding_id, "fact_type" => "intelligence_finding",
        "confidence" => finding.confidence, "status" => "hypothesis",
        "subject" => finding.entity_ids.first, "predicate" => finding.kind,
        "evidence" => evidence, "explanation" => finding.explanation
      }
    end

    def planned_intent(proposal, fact, source_id)
      {
        "planned_intent_id" => proposal.planned_intent_id,
        "intent" => Immutable.canonical(proposal.intent),
        "idempotency_key" => Digest::SHA256.hexdigest(Stable.json(proposal.intent)),
        "fact_ids" => [fact["fact_id"]], "evidence_ids" => proposal.evidence_ids,
        "planning_confidence" => proposal.planning_confidence,
        "risk" => proposal.risk, "approval_requirement" => proposal.approval_requirement,
        "dependencies" => [], "blocked_reasons" => proposal.blocked_reasons,
        "provenance" => { "source_id" => source_id, "finding_id" => proposal.finding_id,
                          "derived" => true },
        "local_references" => {}, "safe_dependency_group" => proposal.planned_intent_id
      }
    end
  end
end
