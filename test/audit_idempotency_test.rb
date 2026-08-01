# frozen_string_literal: true

require_relative "test_helper"

class AuditIdempotencyTest < Minitest::Test
  PERSON_ID = "person_01K1D9VB96W7CS7F4M7K8Q2Z0A"
  RUN_ID = "run_01KYQADDKGCXF0H38JFT5EN0CV"

  class FixedIdGenerator
    def generate(prefix)
      prefix == "person" ? PERSON_ID : "#{prefix}_01K1DCC8Q6V4R5T7S2NXB8K4QW"
    end
  end

  def test_receipt_prevents_duplicate_creation_across_engine_instances_and_audits_replay
    with_schema_vault do |root|
      intent = KnowledgeGraph::CreateEntity.new(
        entity_type: "person",
        attributes: {
          name: "Ada", tier: "active", sensitivity: "private", data_origin: "public", is_self: true
        }
      )
      first_engine = build_engine(root)
      first = first_engine.execute(intent)
      second = build_engine(root).execute(intent)

      assert_equal [PERSON_ID], first.entity_ids
      refute first.replayed
      assert second.replayed
      assert_equal first.changed_paths, second.changed_paths
      assert_equal 1, Dir.glob(File.join(root, "People/*.md")).length
      assert_equal 1, Dir.glob(File.join(root, ".knowledge/runtime/receipts/*.json")).length

      events = first_engine.audit_log.events
      assert_equal 2, events.length
      assert events.all? { |event| event["result"] == "success" }
      assert_equal [false, true], events.map { |event| event["replayed"] }
      assert events.all? { |event| event["rollback"] == false }
      assert events.all? { |event| event["run_id"] == RUN_ID && event["actor_id"] == "test-agent" }
      refute_nil first.audit_id
      refute_nil second.audit_id
    end
  end

  def test_failed_intent_rolls_back_without_receipt_and_is_audited
    with_schema_vault do |root|
      engine = build_engine(root)
      invalid = KnowledgeGraph::CreateEntity.new(
        entity_type: "person",
        attributes: { name: "Invalid", sensitivity: "private", data_origin: "public", is_self: true }
      )

      assert_raises(KnowledgeGraph::ValidationError) { engine.execute(invalid) }

      assert_empty Dir.glob(File.join(root, "People/*.md"))
      assert_empty Dir.glob(File.join(root, ".knowledge/runtime/receipts/*.json"))
      event = engine.audit_log.events.last
      assert_equal "failure", event["result"]
      assert_equal true, event["rollback"]
      assert_equal "KnowledgeGraph::ValidationError", event.dig("error", "class")
    end
  end

  private

  def build_engine(root)
    fixed_time = Time.new(2026, 7, 29, 10, 0, 0, "+03:00")
    KnowledgeGraph::Engine.new(
      vault_root: root,
      run_id: RUN_ID,
      clock: -> { fixed_time },
      id_generator: FixedIdGenerator.new,
      actor_id: "test-agent"
    )
  end
end
