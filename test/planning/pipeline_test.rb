# frozen_string_literal: true

require_relative "test_support"

class PlanningPipelineTest < Minitest::Test
  def test_candidate_generation_scenario_evaluation_and_decision_are_separate
    goal = planning_goal
    engine = planning_engine
    context = KnowledgePlanning::PlanningContext.new(
      snapshot: rich_snapshot, feature_engine: feature_engine,
      as_of: IntelligenceTestSupport::AS_OF
    )
    candidates = engine.candidate_generator.generate(goal, context)

    assert_operator candidates.length, :>=, 1
    assert candidates.all? { |plan| plan.is_a?(KnowledgePlanning::CandidatePlan) }
    refute candidates.any? { |plan| plan.to_h.key?(:utility_score) }

    scenarios = engine.scenario_evaluator.evaluate(goal, candidates, context)
    assert_equal candidates.map(&:plan_id).sort, scenarios.map { |item| item.plan.plan_id }.sort
    assert scenarios.all? { |scenario| scenario.criteria.key?("relationship_strength") }

    result = engine.decision_engine.decide(
      goal: goal, scenarios: scenarios, snapshot_digest: rich_snapshot.digest,
      as_of: IntelligenceTestSupport::AS_OF,
      generator_trace: { "planner_ids" => engine.candidate_generator.planners.map(&:planner_id) }
    )
    refute_nil result.approved_plan
    assert_equal "decision_approved", result.ranked_plans.first.decision_status
    assert_equal false, result.to_h.fetch(:executable)
  end

  def test_multiple_planners_share_one_decision_policy
    goal = planning_goal(goal_type: "fundraising", targets: ["org_fund"])
    result = planning_engine.plan(goal)
    planners = result.ranked_plans.map { |item| item.plan.planner_id }.uniq

    assert_includes planners, "warm_introduction"
    assert_includes planners, "direct_outreach"
    versions = result.ranked_plans.flat_map do |item|
      item.score_trace.map { |_component| result.policy_version }
    end.uniq
    assert_equal ["1.0.0"], versions
  end

  def test_search_simulation_pareto_and_explanation_are_deterministic
    snapshot = rich_snapshot
    search = KnowledgePlanning::GraphSearch.new(snapshot: snapshot, as_of: IntelligenceTestSupport::AS_OF)
    paths = search.alternative_paths("person_self", "person_leaf", mode: "social", limit: 3)
    assert_equal %w[person_self person_ada person_leaf], paths.first

    goal = planning_goal
    first = planning_engine(snapshot).plan(goal)
    second = planning_engine(snapshot).plan(goal)
    assert_equal KnowledgePlanning::Stable.json(first.to_h), KnowledgePlanning::Stable.json(second.to_h)

    approved = first.approved_plan
    assert_operator approved.scenario.simulation.meetings, :>=, 1
    assert_operator approved.scenario.simulation.introductions, :>=, 1
    assert approved.score_trace.all? { |item| item.key?("rule") && item.key?("contribution") }
    assert first.ranked_plans.any?(&:pareto_optimal)
    assert_includes first.trace.fetch("execution_boundary"), "explicit human approval"
  end

  def test_no_cold_outreach_constraint_filters_direct_plan
    goal = planning_goal(
      goal_type: "fundraising", targets: ["org_fund"],
      constraints: { no_cold_outreach: true }
    )
    result = planning_engine.plan(goal)
    cold = result.ranked_plans.select { |item| item.scenario.simulation.cold_outreach }

    assert cold.all? { |item| item.decision_status == "constraint_rejected" }
    assert result.approved_plan.scenario.feasible?
  end
end
