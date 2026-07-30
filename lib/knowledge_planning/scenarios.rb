# frozen_string_literal: true

module KnowledgePlanning
  class ScenarioEvaluator
    FEATURE_NAMES = %w[relationship_strength trust_score recency_score].freeze

    def initialize(simulator: PlanSimulator.new)
      @simulator = simulator
    end

    def evaluate(goal, candidates, context)
      Array(candidates).sort_by(&:plan_id).map do |plan|
        simulation = @simulator.simulate(plan)
        trace = feature_trace(plan, context)
        criteria = criteria_for(goal, plan, simulation, trace)
        violations = goal.constraints.violations(
          plan: plan, simulation: simulation, goal: goal, as_of: context.as_of
        )
        ScenarioEvaluation.new(
          plan: plan, simulation: simulation, criteria: criteria, feature_trace: trace,
          violations: violations, benefits: benefits(plan, criteria), risks: risks(plan, simulation),
          cost: { "budget" => simulation.budget, "effort_units" => plan.estimated_effort,
                  "duration_days" => simulation.duration_days },
          expected_outcome: expected_outcome(plan, simulation), confidence: simulation.confidence
        )
      end.freeze
    end

    private

    def feature_trace(plan, context)
      people = Array(plan.metadata["entity_ids"]).map { |id| context.snapshot.record(id) }
        .compact.select { |record| record.type == "person" && record.id != context.snapshot.self_id }
      people.sort_by(&:id).flat_map do |person|
        FEATURE_NAMES.map do |name|
          options = { subject_id: person.id }
          options[:object_id] = context.snapshot.self_id if name != "trust_score" && context.snapshot.self_id
          value = context.feature_engine.fetch(name, **options)
          {
            "feature" => name, "entity_id" => person.id, "value" => value.value,
            "evidence_ids" => value.evidence.map(&:evidence_id), "explanation" => value.explanation
          }
        rescue KnowledgeIntelligence::Error
          nil
        end.compact
      end.freeze
    end

    def criteria_for(goal, plan, simulation, trace)
      values = FEATURE_NAMES.each_with_object({}) do |name, result|
        selected = trace.select { |item| item.fetch("feature") == name }.map { |item| item.fetch("value") }.compact
        result[name] = selected.empty? ? 0.0 : (selected.sum.to_f / selected.length).round(6)
      end
      evidence_support = [plan.evidence.length.to_f / [plan.steps.length, 1].max, 1.0].min
      values.merge(
        "goal_relevance" => goal_relevance(goal, plan),
        "preference_alignment" => plan.metadata.fetch("preference_alignment", 0.5).to_f,
        "evidence_support" => evidence_support.round(6),
        "value" => plan.estimated_value,
        "confidence" => simulation.confidence,
        "effort_efficiency" => (1.0 / (1.0 + plan.estimated_effort / 10.0)).round(6),
        "risk_safety" => (1.0 - plan.risk_score).round(6)
      ).freeze
    end

    def goal_relevance(goal, plan)
      expected = Array(goal.preferences["target_ids"]).map(&:to_s)
      covered = Array(plan.metadata["target_ids"]).map(&:to_s)
      target_score = expected.empty? ? 0.75 : (covered & expected).length.to_f / expected.length
      strategy_score = plan.planner_id.include?(goal.goal_type) ? 1.0 : 0.75
      (0.7 * target_score + 0.3 * strategy_score).round(6)
    end

    def benefits(plan, criteria)
      (Array(plan.metadata["benefits"]) + [
        "Goal relevance #{criteria.fetch('goal_relevance').round(3)}",
        "Evidence support #{criteria.fetch('evidence_support').round(3)}"
      ]).uniq
    end

    def risks(plan, simulation)
      values = []
      values << "Cold outreach is required" if simulation.cold_outreach
      values << "Travel is required" if simulation.travel_required
      values << "Plan risk is #{plan.risk}" unless plan.risk == "low"
      values << "Graph evidence is sparse" if plan.evidence.empty?
      values
    end

    def expected_outcome(plan, simulation)
      "#{plan.title}: #{simulation.meetings} meeting(s), #{simulation.introductions} introduction(s), " \
        "#{simulation.followups} follow-up(s), and #{simulation.duration_days} estimated day(s)."
    end
  end
end
