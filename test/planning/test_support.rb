# frozen_string_literal: true

require_relative "../intelligence/test_support"

module PlanningTestSupport
  GOAL_ID = "goal_01K1D9VB96W7CS7F4M7K8Q2Z0A".freeze

  def planning_goal(goal_type: "warm_introduction", targets: ["person_leaf"], constraints: {}, preferences: {})
    KnowledgePlanning::Goal.new(
      id: GOAL_ID, description: "Synthetic planning goal", goal_type: goal_type,
      priority: "high", constraints: constraints,
      preferences: { "target_ids" => targets }.merge(preferences),
      success_criteria: ["Produce a reviewable next step"]
    )
  end

  def planning_engine(snapshot = rich_snapshot, planners: KnowledgePlanning::DefaultPlanners.build)
    KnowledgePlanning::Engine.new(
      snapshot: snapshot, as_of: IntelligenceTestSupport::AS_OF, planners: planners
    )
  end
end

class Minitest::Test
  include PlanningTestSupport
end
