# frozen_string_literal: true

require_relative "test_support"

class KnowledgeActivityReversalTest < Minitest::Test
  def test_undo_and_restore_only_create_approved_proposals_before_engine_execution
    with_activity_vault do |root, engine, orchestrator, timeline, set_time, clock|
      original_result = create_person(engine)
      original = timeline.call.latest
      before = File.read(File.join(root, "People/Ada Lovelace.md"))

      set_time.call(10)
      undo_response = timeline.call.create_proposal(original.id, operation: :undo)
      proposal_id = undo_response.fetch(:proposal)
      assert_equal "active", repository_for(root).find(KnowledgeActivityTestSupport::PERSON_ID).data.fetch("record_status")
      assert_equal before, File.read(File.join(root, "People/Ada Lovelace.md"))

      store = KnowledgeExtraction::ProposalStore.new(vault_root: root, clock: clock)
      proposal = store.load(proposal_id)
      assert KnowledgeExtraction::ProposalValidator.new.validate!(proposal)
      assert_equal "ArchiveEntity", proposal.dig("planned_intents", 0, "intent", "type")
      assert proposal.fetch("planned_intents").all? do |item|
        item.fetch("approval_requirement") == "human_review" && item.fetch("planning_confidence") == 1.0
      end
      approved_ids = proposal.fetch("planned_intents").map { |item| item.fetch("planned_intent_id") }
      store.approve(proposal_id: proposal_id, intent_ids: approved_ids, actor_id: "alex")
      submission = KnowledgeExtraction::ProposalSubmitter.new(
        engine: engine, store: store, clock: clock
      ).submit(proposal_id)
      assert_equal "executed", submission.fetch("status")
      assert_equal "archived", repository_for(root).find(KnowledgeActivityTestSupport::PERSON_ID).data.fetch("record_status")

      undo_activity = timeline.call.latest
      assert_equal proposal_id, undo_activity.proposal
      assert_equal "knowledge_archived", undo_activity.type
      assert_equal original.source, undo_activity.source

      set_time.call(11)
      restore_response = timeline.call.create_proposal(original.id, operation: :restore)
      restore_id = restore_response.fetch(:proposal)
      restore = store.load(restore_id)
      assert_equal "RestoreEntity", restore.dig("planned_intents", 0, "intent", "type")
      restore_ids = restore.fetch("planned_intents").map { |item| item.fetch("planned_intent_id") }
      store.approve(proposal_id: restore_id, intent_ids: restore_ids, actor_id: "alex")
      restored = KnowledgeExtraction::ProposalSubmitter.new(
        engine: engine, store: store, clock: clock
      ).submit(restore_id)
      assert_equal "executed", restored.fetch("status")
      assert_equal "active", repository_for(root).find(KnowledgeActivityTestSupport::PERSON_ID).data.fetch("record_status")

      event_count = orchestrator.event_bus.store.events.length
      replayed = engine.execute(KnowledgeGraph::IntentFactory.build(original.audit.fetch("intent")))
      assert replayed.replayed
      assert_equal event_count, orchestrator.event_bus.store.events.length
      assert_equal original_result.entity_ids, replayed.entity_ids
    end
  end
end
