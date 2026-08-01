# frozen_string_literal: true

require_relative "../test_helper"

module KnowledgeActivityTestSupport
  ACTIVITY_RUN_ID = "run_01KYY9NVA2N5B4CN6N56ZNZ364"
  PERSON_ID = "person_01KYYA00000000000000000001"
  ORG_ID = "org_01KYYA00000000000000000002"

  def with_activity_vault
    with_schema_vault do |root|
      current_time = Time.new(2026, 8, 1, 9, 0, 0, "+03:00")
      clock = -> { current_time }
      set_time = ->(hour) { current_time = Time.new(2026, 8, 1, hour, 0, 0, "+03:00") }
      orchestrator = KnowledgeOrchestration.build(
        vault_root: root, run_id: KnowledgeActivityTestSupport::ACTIVITY_RUN_ID,
        actor_id: "alex", clock: clock,
        threaded_workflows: false
      )
      engine = KnowledgeOrchestration::EngineEventBridge.new(event_bus: orchestrator.event_bus).attach(
        KnowledgeGraph::Engine.new(
          vault_root: root, run_id: KnowledgeActivityTestSupport::ACTIVITY_RUN_ID,
          actor_id: "alex", clock: clock
        )
      )
      timeline = lambda do
        KnowledgeActivity::Timeline.new(
          vault_root: root, clock: clock, event_store: orchestrator.event_bus.store,
          event_bus: orchestrator.event_bus, cache: orchestrator.cache
        )
      end
      yield root, engine, orchestrator, timeline, set_time, clock
    end
  end

  def create_person(engine, sensitivity: "private", name: "Ada Lovelace")
    engine.execute(
      KnowledgeGraph::CreateEntity.new(
        entity_type: "person",
        attributes: {
          id: KnowledgeActivityTestSupport::PERSON_ID, name: name, tier: "active", sensitivity: sensitivity,
          data_origin: "public", is_self: true
        }
      )
    )
  end

  def repository_for(root)
    registry = KnowledgeGraph::SchemaRegistry.new(vault_root: root)
    KnowledgeGraph::Repository.new(vault_root: root, registry: registry)
  end
end

class Minitest::Test
  include KnowledgeActivityTestSupport
end
