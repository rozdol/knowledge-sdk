# frozen_string_literal: true

require_relative "test_helper"

class EngineTest < Minitest::Test
  def test_dispatches_every_execution_through_registered_handler
    with_vault do |root|
      seen = []
      engine = KnowledgeGraph::Engine.new(vault_root: root)
      engine.register(KnowledgeGraph::ArchiveEntity) do |intent|
        seen << intent
        { archived: intent.entity_id }
      end
      intent = KnowledgeGraph::ArchiveEntity.new(entity_id: "person_1")

      result = engine.execute(intent)

      assert_equal [intent], seen
      assert_equal({ archived: "person_1" }, result.value)
      assert_equal "ArchiveEntity", result.intent_type
    end
  end

  def test_rejects_non_intents_and_unregistered_intents
    with_vault do |root|
      engine = KnowledgeGraph::Engine.new(vault_root: root)

      assert_raises(KnowledgeGraph::InvalidIntent) { engine.execute(Object.new) }
      assert_raises(KnowledgeGraph::UnsupportedIntent) do
        engine.execute(KnowledgeGraph::ArchiveEntity.new(entity_id: "person_1"))
      end
    end
  end
end
