# frozen_string_literal: true

require_relative "test_helper"

class EngineTest < Minitest::Test
  class UnknownIntent < KnowledgeGraph::Intent; end

  def test_dispatches_every_execution_through_registered_handler
    with_vault do |root|
      seen = []
      engine = KnowledgeGraph::Engine.new(vault_root: root, validator: ->(_context) {})
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

  def test_runs_hooks_and_commits_staged_changes_in_pipeline_order
    with_vault do |root|
      events = []
      engine = KnowledgeGraph::Engine.new(vault_root: root, validator: ->(_context) {})
      %i[before_execute after_execute before_commit after_commit].each do |event|
        engine.on(event) { events << event }
      end
      engine.register(KnowledgeGraph::ArchiveEntity) do |intent, context|
        context.transaction.write("result.txt", intent.entity_id)
        :written
      end

      result = engine.execute(KnowledgeGraph::ArchiveEntity.new(entity_id: "person_1"))

      assert_equal %i[before_execute after_execute before_commit after_commit], events
      assert_equal "person_1", File.read(File.join(root, "result.txt"))
      assert_equal ["result.txt"], result.changed_paths
      assert_operator result.duration_ms, :>=, 0
    end
  end

  def test_rolls_back_when_handler_fails
    with_vault do |root|
      events = []
      engine = KnowledgeGraph::Engine.new(vault_root: root, validator: ->(_context) {})
      engine.on(:before_rollback) { events << :before_rollback }
      engine.on(:after_rollback) { events << :after_rollback }
      engine.register(KnowledgeGraph::ArchiveEntity) do |_intent, context|
        context.transaction.write("result.txt", "should not exist")
        raise "handler failed"
      end

      assert_raises(RuntimeError) do
        engine.execute(KnowledgeGraph::ArchiveEntity.new(entity_id: "person_1"))
      end
      refute File.exist?(File.join(root, "result.txt"))
      assert_equal %i[before_rollback after_rollback], events
    end
  end

  def test_rejects_non_intents_and_unregistered_intents
    with_vault do |root|
      engine = KnowledgeGraph::Engine.new(vault_root: root, validator: ->(_context) {})

      assert_raises(KnowledgeGraph::InvalidIntent) { engine.execute(Object.new) }
      assert_raises(KnowledgeGraph::UnsupportedIntent) do
        engine.execute(UnknownIntent.new)
      end
    end
  end

  def test_refuses_to_execute_when_the_required_validator_is_missing
    with_vault do |root|
      engine = KnowledgeGraph::Engine.new(vault_root: root)
      engine.register(UnknownIntent) { :handled }

      error = assert_raises(KnowledgeGraph::ValidationError) { engine.execute(UnknownIntent.new) }

      assert_includes error.message, "required vault validator not found"
    end
  end
end
