# frozen_string_literal: true

module KnowledgePlanning
  class Engine
    attr_reader :snapshot, :as_of, :candidate_generator, :scenario_evaluator,
                :decision_engine

    def initialize(snapshot:, as_of: Date.today, planners: DefaultPlanners.build,
                   policy: DecisionPolicy.load, feature_registry: KnowledgeIntelligence::DefaultFeatures.registry)
      @snapshot = snapshot
      @as_of = as_of.is_a?(Date) ? as_of : Date.iso8601(as_of.to_s)
      feature_engine = KnowledgeIntelligence::FeatureEngine.new(
        snapshot: snapshot, registry: feature_registry, as_of: @as_of
      )
      @context = PlanningContext.new(snapshot: snapshot, feature_engine: feature_engine, as_of: @as_of)
      @candidate_generator = CandidatePlanGenerator.new(planners: planners)
      @scenario_evaluator = ScenarioEvaluator.new
      @decision_engine = DecisionEngine.new(policy: policy)
    end

    def plan(goal)
      raise InvalidGoal, "only active goals can be planned" unless goal.active?

      candidates = candidate_generator.generate(goal, @context)
      scenarios = scenario_evaluator.evaluate(goal, candidates, @context)
      generator_trace = {
        "planner_ids" => candidate_generator.planners.select { |planner| planner.supports?(goal) }.map(&:planner_id),
        "candidate_count" => candidates.length,
        "separation" => "candidate generation performs no ranking"
      }
      decision_engine.decide(
        goal: goal, scenarios: scenarios, snapshot_digest: snapshot.digest,
        as_of: as_of, generator_trace: generator_trace
      )
    end
  end
end
