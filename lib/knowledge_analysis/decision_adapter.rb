# frozen_string_literal: true

module KnowledgeAnalysis
  # Adapts derived recommendations to the existing Planning/Decision policy.
  # Candidate Plans contain review steps only and never generated Intents.
  class DecisionAdapter
    def initialize(decision_engine: KnowledgePlanning::DecisionEngine.new)
      @decision_engine = decision_engine
    end

    def rank(question:, recommendations:, snapshot_digest:, as_of:)
      selected = Array(recommendations)
      return [selected, empty_trace] if selected.empty?

      goal = KnowledgePlanning::Goal.new(
        id: KnowledgePlanning::Stable.id("goal", "analysis-recommendation", question),
        description: "Review possible recommendations for: #{question}",
        goal_type: "analysis_recommendation", priority: "normal",
        success_criteria: ["Retain explicit evidence, confidence, and human review"]
      )
      scenarios = selected.map { |item| scenario(goal, item) }
      decision = @decision_engine.decide(
        goal: goal, scenarios: scenarios, snapshot_digest: snapshot_digest,
        as_of: as_of,
        generator_trace: {
          "adapter" => "knowledge-analysis", "candidate_kind" => "review_only_recommendation",
          "generated_intents" => 0
        }
      )
      by_id = selected.to_h { |item| [item.fetch("recommendation_id"), item] }
      ranking = decision.ranked_plans.map do |ranked|
        recommendation_id = ranked.plan.metadata.fetch("recommendation_id")
        {
          "rank" => ranked.rank, "recommendation_id" => recommendation_id,
          "decision_status" => ranked.decision_status,
          "utility_score" => ranked.utility_score, "explanation" => ranked.explanation
        }
      end
      ordered = ranking.map { |item| by_id.fetch(item.fetch("recommendation_id")) }
      trace = {
        "policy_version" => decision.policy_version,
        "chosen_recommendation_id" => ranking.first && ranking.first.fetch("recommendation_id"),
        "ranking" => ranking,
        "generated_intents" => 0,
        "decision_approved_is_executable" => false,
        "execution_boundary" => "Recommendation review -> separate concrete Intent Proposal -> exact approval -> Engine"
      }
      [ordered, trace]
    end

    private

    def scenario(goal, recommendation)
      identifier = recommendation.fetch("recommendation_id")
      confidence = recommendation.fetch("confidence").to_f
      step = KnowledgePlanning::PlanStep.new(
        seed: identifier, action: "review_recommendation",
        description: recommendation.fetch("text"), required_approval: "human_review"
      )
      plan = KnowledgePlanning::CandidatePlan.new(
        goal_id: goal.id, planner_id: "knowledge-analysis-recommendation",
        planner_version: KnowledgeAnalysis::VERSION, title: recommendation.fetch("text"),
        steps: [step], estimated_effort: 1.0, estimated_value: confidence,
        confidence: confidence, evidence: [], risk: "low",
        metadata: {
          "recommendation_id" => identifier, "preference_alignment" => 0.5,
          "benefits" => ["Preserves explicit human review"]
        }
      )
      simulation = KnowledgePlanning::SimulationResult.new(
        meetings: 0, introductions: 0, followups: 0, duration_days: 0,
        budget: 0, travel_required: false, cold_outreach: false,
        confidence: confidence
      )
      evidence_count = Array(recommendation["evidence"]).length
      criteria = {
        "confidence" => confidence, "effort_efficiency" => 0.9,
        "evidence_support" => [evidence_count.to_f / 5.0, 1.0].min,
        "goal_relevance" => 0.9, "preference_alignment" => 0.5,
        "recency_score" => 0.5, "relationship_strength" => 0.5,
        "risk_safety" => 0.8, "trust_score" => 0.5, "value" => confidence
      }
      KnowledgePlanning::ScenarioEvaluation.new(
        plan: plan, simulation: simulation, criteria: criteria,
        feature_trace: { "source" => "knowledge-analysis", "recommendation_id" => identifier },
        violations: [], benefits: ["Review-only recommendation"],
        risks: ["Observational evidence may be confounded"],
        cost: { "budget" => 0, "effort_units" => 1.0, "duration_days" => 0 },
        expected_outcome: "A human reviews the recommendation and cited evidence.",
        confidence: confidence
      )
    end

    def empty_trace
      {
        "policy_version" => @decision_engine.policy.version,
        "chosen_recommendation_id" => nil, "ranking" => [],
        "generated_intents" => 0, "decision_approved_is_executable" => false,
        "execution_boundary" => "No recommendation candidates were available."
      }
    end
  end
end
