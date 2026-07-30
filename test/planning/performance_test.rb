# frozen_string_literal: true

require_relative "test_support"

class PlanningPerformanceTest < Minitest::Test
  def test_bounded_candidate_generation_on_a_large_synthetic_contact_set
    base = rich_snapshot.records(active_only: false)
    generated = 600.times.flat_map do |index|
      id = "synthetic_person_#{index.to_s.rjust(4, '0')}"
      person = snapshot_record(id, "person", "Synthetic Dormant #{index.to_s.rjust(4, '0')}",
                               "People/Synthetic Dormant #{index.to_s.rjust(4, '0')}.md", {
                                 "tier" => "dormant", "sensitivity" => "private",
                                 "data_origin" => "public"
                               })
      edge = relationship("synthetic_rel_#{index.to_s.rjust(4, '0')}", "person_self", "knows", id, "weak")
      [person, edge]
    end
    snapshot = KnowledgeIntelligence::GraphSnapshot.new(base + generated)
    goal = planning_goal(goal_type: "relationship_maintenance", targets: [], preferences: {
      "candidate_limit" => 10, "maximum_candidates" => 10
    })

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = planning_engine(snapshot).plan(goal)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal 10, result.ranked_plans.length
    assert_operator elapsed, :<, 5.0
    assert_equal result.to_h, planning_engine(snapshot).plan(goal).to_h
  end
end
