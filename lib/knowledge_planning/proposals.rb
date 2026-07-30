# frozen_string_literal: true

require "digest"

module KnowledgePlanning
  class ProposalAdapter
    PIPELINE_VERSION = "knowledge-planning-8.0.0".freeze

    def build(decision_result)
      ranked = decision_result.approved_plan
      raise ProposalFailure, "decision has no constraint-feasible approved plan" unless ranked

      plan = ranked.plan
      steps = plan.steps.select(&:intent)
      raise ProposalFailure, "approved plan has no generated Intent proposals" if steps.empty?

      source_id = Stable.id("source", decision_result.decision_id)
      fact = fact_for(decision_result, ranked)
      intents = steps.each_with_index.map do |step, index|
        planned_intent(step, index, fact, source_id, ranked)
      end
      proposal_id = Stable.id("proposal", source_id, intents.map { |item| item.fetch("planned_intent_id") })
      payload = {
        "proposal_id" => proposal_id,
        "source" => {
          "source_id" => source_id, "source_type" => "text", "language" => "und",
          "captured_at" => "#{decision_result.as_of}T00:00:00Z",
          "title" => "Planning decision #{decision_result.decision_id}",
          "metadata" => {
            "snapshot_digest" => decision_result.snapshot_digest,
            "decision_id" => decision_result.decision_id, "plan_id" => plan.plan_id,
            "derived" => true
          },
          "content_hash" => Digest::SHA256.hexdigest(Stable.json(fact))
        },
        "summary" => "#{intents.length} reviewable Intent proposal(s) from the decision-approved plan.",
        "facts" => [fact], "entity_mentions" => [], "resolution_candidates" => [],
        "resolution_decisions" => [], "planned_intents" => intents,
        "warnings" => [], "conflicts" => [],
        "required_approvals" => intents.map do |item|
          { "planned_intent_id" => item.fetch("planned_intent_id"),
            "requirement" => item.fetch("approval_requirement") }
        end,
        "rejected_items" => [], "model_metadata" => { "provider" => "none", "deterministic" => true },
        "prompt_version" => "none", "pipeline_version" => PIPELINE_VERSION,
        "created_at" => "#{decision_result.as_of}T00:00:00Z", "status" => "awaiting_approval",
        "ingestion_state" => "new",
        "metrics" => {
          "candidate_count" => decision_result.ranked_plans.length,
          "intent_count" => intents.length, "utility_score" => ranked.utility_score
        }
      }
      KnowledgeExtraction::ProposalValidator.new.validate!(payload)
      Immutable.copy(payload)
    rescue KnowledgeExtraction::PlanningFailure => error
      raise ProposalFailure, error.message
    end

    def persist(payload, vault_root:)
      KnowledgeExtraction::ProposalStore.new(vault_root: vault_root).save(payload)
    end

    private

    def fact_for(decision_result, ranked)
      evidence = ranked.plan.evidence.map do |item|
        item.to_h.transform_keys(&:to_s).merge("quote" => item.value.to_s)
      end
      {
        "fact_id" => Stable.id("fact", decision_result.decision_id, ranked.plan.plan_id),
        "finding_id" => decision_result.decision_id, "fact_type" => "planning_decision",
        "confidence" => ranked.scenario.confidence, "status" => "hypothesis",
        "subject" => decision_result.goal.id, "predicate" => "decision_approved_plan",
        "object" => ranked.plan.plan_id, "evidence" => evidence,
        "explanation" => ranked.explanation
      }
    end

    def planned_intent(step, index, fact, source_id, ranked)
      planned_id = Stable.id("planned-intent", ranked.plan.plan_id, step.step_id, index)
      {
        "planned_intent_id" => planned_id,
        "intent" => Immutable.canonical(step.intent),
        "idempotency_key" => Digest::SHA256.hexdigest(Stable.json(step.intent)),
        "fact_ids" => [fact.fetch("fact_id")],
        "evidence_ids" => fact.fetch("evidence").map { |item| item.fetch("evidence_id") },
        "planning_confidence" => ranked.scenario.confidence,
        "risk" => ranked.plan.risk, "approval_requirement" => "human_review",
        "dependencies" => [], "blocked_reasons" => [],
        "provenance" => {
          "source_id" => source_id, "decision_id" => ranked.scenario.scenario_id,
          "plan_id" => ranked.plan.plan_id, "step_id" => step.step_id, "derived" => true
        },
        "local_references" => {}, "safe_dependency_group" => ranked.plan.plan_id
      }
    end
  end
end
