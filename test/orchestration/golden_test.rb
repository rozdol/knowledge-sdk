# frozen_string_literal: true

require_relative "test_support"

class OrchestrationGoldenTest < Minitest::Test
  SCENARIOS = {
    "MeetingImported" => ["meeting_imported", %w[kg.extraction.extract_source kg.orchestration.notify]],
    "TranscriptExtracted" => ["transcript_extracted", %w[kg.extraction.extract_source kg.orchestration.notify]],
    "GoalCreated" => ["goal_created", %w[kg.planning.plan kg.orchestration.notify]],
    "DeadlineReached" => ["deadline_reached", %w[kg.planning.plan kg.planning.create_proposal kg.orchestration.notify]],
    "FollowupOverdue" => ["followup_overdue", %w[kg.intelligence.followup_status kg.orchestration.notify]],
    "PlannerCompleted" => ["planner_finished", %w[kg.intelligence.digest kg.orchestration.notify]],
    "ProposalApproved" => ["proposal_approved", %w[kg.proposals.status kg.orchestration.notify]],
    "ProposalRejected" => ["proposal_rejected", %w[kg.orchestration.notify]],
    "RelationshipUpdated" => ["relationship_changed", %w[kg.intelligence.analyze kg.orchestration.notify]],
    "DigestRequested" => ["digest_requested", %w[kg.intelligence.digest kg.orchestration.notify]]
  }.freeze

  def test_golden_scenarios_cover_required_coordination_boundaries
    registry = KnowledgeOrchestration::WorkflowRegistry.new(
      KnowledgeOrchestration::WorkflowLoader.new.load(KnowledgeOrchestration::DEFAULT_WORKFLOW_PATH)
    )
    SCENARIOS.each do |event_type, (workflow_id, capabilities)|
      workflow = registry.fetch(workflow_id)
      assert_includes workflow.trigger_types, event_type
      assert_equal capabilities.sort, workflow.steps.map(&:capability_id).sort
      refute_includes workflow.steps.map(&:capability_id), "kg.proposals.submit"
    end
  end
end
