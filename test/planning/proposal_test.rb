# frozen_string_literal: true

require_relative "test_support"

class PlanningProposalTest < Minitest::Test
  def test_decision_proposal_is_review_only_and_uses_existing_validator
    goal = planning_goal(goal_type: "customer_recovery", targets: ["person_cara"])
    result = planning_engine.plan(goal)
    payload = KnowledgePlanning::ProposalAdapter.new.build(result)

    assert_equal "awaiting_approval", payload.fetch("status")
    assert_equal true, payload.fetch("model_metadata").fetch("deterministic")
    assert payload.fetch("planned_intents").all? do |item|
      item.fetch("approval_requirement") == "human_review" && item.fetch("blocked_reasons").empty?
    end
    assert KnowledgeExtraction::ProposalValidator.new.validate!(payload)
  end

  def test_planning_has_no_engine_or_graph_writer_dependency
    constants = KnowledgePlanning.constants.map(&:to_s)
    refute_includes constants, "Executor"
    refute_includes constants, "Dispatcher"

    serialized = File.read(File.expand_path("../../lib/knowledge_planning/engine.rb", __dir__))
    refute_includes serialized, "KnowledgeGraph::Engine"
    refute_includes serialized, ".execute("
  end
end
