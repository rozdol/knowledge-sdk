# frozen_string_literal: true

require_relative "../test_helper"

class KnowledgeCaptureWorkflowTest < Minitest::Test
  FIXED_TIME = Time.utc(2026, 8, 6, 10, 0, 0)
  RUN_ID = "run_01KZAE8M00QG5K6E7P8R9S0T1V"
  PROJECT_ID = "project_01KZAE8M00QG5K6E7P8R9S0T2V"
  PERSON_ID = "person_01KZAE8M00QG5K6E7P8R9S0T3V"

  def test_creation_and_candidate_linking_require_exact_approval
    with_schema_vault do |root|
      create_link_targets(root)
      store = KnowledgeExtraction::ProposalStore.new(vault_root: root, clock: -> { FIXED_TIME })
      result = KnowledgeCapture::CaptureProposalBuilder.new(
        vault_root: root, proposal_store: store, clock: -> { FIXED_TIME }
      ).create(
        "source_type" => "chat",
        "content" => "I have an idea: automate Tqoia reports with Ivan Petrov.",
        "captured_at" => FIXED_TIME.iso8601, "sender" => "synthetic-user"
      )

      assert_equal "awaiting_approval", result.fetch("status")
      assert_equal 2, result.fetch("planned_intent_count")
      assert_equal %w[contact project], result.fetch("candidate_links").map { |item| item.fetch("category") }.sort
      assert_empty KnowledgeCapture::Store.new(vault_root: root).all

      proposal = store.load(result.fetch("proposal_id"))
      planned_ids = proposal.fetch("planned_intents").map { |item| item.fetch("planned_intent_id") }
      store.approve(
        proposal_id: result.fetch("proposal_id"), intent_ids: planned_ids,
        actor_id: "human:test"
      )
      submission = KnowledgeExtraction::ProposalSubmitter.new(
        engine: KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME }),
        store: store, clock: -> { FIXED_TIME }
      ).submit(result.fetch("proposal_id"))
      assert_equal "executed", submission.fetch("status")

      capture = KnowledgeCapture::Store.new(vault_root: root).all.first
      assert_equal "idea", capture.kind
      assert_equal "linked", capture.status
      assert_equal [PROJECT_ID], capture.related_projects
      assert_equal [PERSON_ID], capture.related_contacts
      assert_equal "automate Tqoia reports with Ivan Petrov.", capture.body.strip
      assert File.file?(File.join(root, "Captures", "#{capture.id}.md"))
    end
  end

  def test_promotion_is_a_separate_approved_proposal_and_preserves_original_content
    with_schema_vault do |root|
      create_link_targets(root)
      engine = KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME })
      created = engine.execute(KnowledgeGraph::CreateCapture.new(
        capture_id: "capture_01KZAE8M00QG5K6E7P8R9S0T4V", kind: "idea",
        title: "Automate reports", body: "Keep the immutable original wording.",
        captured_at: FIXED_TIME.iso8601, language: "en", source: "test"
      ))
      capture = KnowledgeCapture::Store.new(vault_root: root).find(created.entity_ids.first)
      original_body = capture.body
      store = KnowledgeExtraction::ProposalStore.new(vault_root: root, clock: -> { FIXED_TIME })
      result = KnowledgeCapture::PromotionProposalBuilder.new(
        vault_root: root, proposal_store: store, clock: -> { FIXED_TIME }
      ).create(capture: capture, target_kind: "project", target_ids: [PROJECT_ID])
      assert_equal "knowledge.capture.promote", result.fetch("intent")
      assert_equal "inbox", KnowledgeCapture::Store.new(vault_root: root).find(capture.id).status

      proposal = store.load(result.fetch("proposal_id"))
      ids = proposal.fetch("planned_intents").map { |item| item.fetch("planned_intent_id") }
      store.approve(proposal_id: result.fetch("proposal_id"), intent_ids: ids, actor_id: "human:test")
      submission = KnowledgeExtraction::ProposalSubmitter.new(
        engine: engine, store: store, clock: -> { FIXED_TIME }
      ).submit(result.fetch("proposal_id"))
      assert_equal "executed", submission.fetch("status")

      promoted = KnowledgeCapture::Store.new(vault_root: root).find(capture.id)
      assert_equal "promoted", promoted.status
      assert_equal "project", promoted.promotion_kind
      assert_equal [PROJECT_ID], promoted.promoted_to
      assert_equal original_body, promoted.body
    end
  end

  def test_review_and_archive_are_independent_engine_intents
    with_vault do |root|
      engine = KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME })
      result = engine.execute(KnowledgeGraph::CreateCapture.new(
        capture_id: "capture_01KZAE8M00QG5K6E7P8R9S0T5V", kind: "note",
        title: "Review me", body: "A synthetic review note.",
        captured_at: FIXED_TIME.iso8601
      ))
      id = result.entity_ids.first
      engine.execute(KnowledgeGraph::ReviewCapture.new(capture_id: id))
      assert_equal "reviewed", KnowledgeCapture::Store.new(vault_root: root).find(id).status
      engine.execute(KnowledgeGraph::ArchiveCapture.new(capture_id: id))
      archived = KnowledgeCapture::Store.new(vault_root: root).find(id)
      assert_equal "archived", archived.status
      assert_equal "archived", archived.data.fetch("record_status")
    end
  end

  private

  def create_link_targets(root)
    engine = KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME })
    engine.execute(KnowledgeGraph::CreateEntity.new(
      entity_type: "project", attributes: {
        id: PROJECT_ID, name: "Tqoia", project_status: "active"
      }
    ))
    engine.execute(KnowledgeGraph::CreateEntity.new(
      entity_type: "person", attributes: {
        id: PERSON_ID, name: "Ivan Petrov", tier: "active",
        sensitivity: "private", data_origin: "public"
      }
    ))
  end
end
