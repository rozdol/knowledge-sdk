# frozen_string_literal: true

require_relative "test_support"

class PlanningGoldenTest < Minitest::Test
  def test_eight_domain_scenarios_produce_expected_candidate_strategies
    cases.each do |item|
      values = item.fetch("goal")
      goal = KnowledgePlanning::Goal.new(
        id: KnowledgePlanning::Stable.id("goal", item.fetch("id")),
        description: values.fetch("description"), goal_type: values.fetch("goal_type"),
        constraints: values.fetch("constraints", {}), preferences: values.fetch("preferences", {})
      )
      result = planning_engine.plan(goal)
      actual = result.ranked_plans.map { |ranked| ranked.plan.planner_id }.uniq.sort

      assert_equal item.fetch("expected_planners").sort, actual, item.fetch("id")
      assert_equal item.fetch("expected_selected_planner"), result.approved_plan.plan.planner_id, item.fetch("id")
      assert result.ranked_plans.all? { |ranked| !ranked.explanation.empty? }, item.fetch("id")
      assert result.ranked_plans.all? { |ranked| ranked.score_trace.all? { |score| score["rule_id"] } }, item.fetch("id")
      assert_equal result.to_h, planning_engine.plan(goal).to_h, item.fetch("id")
    end
  end

  private

  def cases
    path = File.expand_path("golden/cases.json", __dir__)
    JSON.parse(File.read(path))
  end
end
