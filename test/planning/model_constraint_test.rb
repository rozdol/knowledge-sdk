# frozen_string_literal: true

require_relative "test_support"

class PlanningModelConstraintTest < Minitest::Test
  def test_goal_is_immutable_and_constraint_sets_compose
    base = KnowledgePlanning::ConstraintSet.new(max_meetings: 2, no_cold_outreach: true)
    merged = base.merge(budget: 250)
    goal = planning_goal(constraints: merged.to_h)

    assert goal.frozen?
    assert goal.constraints.frozen?
    assert_equal 2, goal.constraints["maximum_meetings"]
    assert_equal 250.0, goal.constraints["budget"]
    assert_raises(FrozenError) { goal.preferences["target_ids"] << "person_ada" }
    assert_raises(KnowledgePlanning::InvalidConstraint) do
      KnowledgePlanning::ConstraintSet.new(opaque_rule: true)
    end
  end

  def test_hard_constraints_reject_plans_before_decision_approval
    goal = planning_goal(constraints: { maximum_meetings: 0, maximum_introductions: 0 })
    result = planning_engine.plan(goal)

    assert_nil result.approved_plan
    assert result.ranked_plans.all? { |item| item.decision_status == "constraint_rejected" }
    assert result.ranked_plans.all? { |item| !item.scenario.violations.empty? }
  end

  def test_goal_store_is_runtime_state_not_graph_markdown
    with_schema_vault do |root|
      before = markdown_hashes(root)
      clock = -> { Time.utc(2026, 7, 30, 8, 0, 0) }
      store = KnowledgePlanning::GoalStore.new(vault_root: root, clock: clock)
      created = store.create(
        description: "Synthetic stored goal", goal_type: "generic",
        constraints: { budget: 100 }, success_criteria: ["Review options"]
      )

      assert_equal created.to_h, store.fetch(created.id).to_h
      assert_equal "archived", store.archive(created.id).status
      assert_equal before, markdown_hashes(root)
    end
  end

  private

  def markdown_hashes(root)
    Dir.glob(File.join(root, "**/*.md")).sort.to_h do |path|
      [path.sub("#{root}/", ""), Digest::SHA256.file(path).hexdigest]
    end
  end
end
