# frozen_string_literal: true

require_relative "test_support"

class OrchestrationIntegrationTest < Minitest::Test
  def test_notification_workflow_runs_through_gateway_and_replays_identically
    with_schema_vault do |root|
      orchestrator = KnowledgeOrchestration.build(
        vault_root: root, run_id: ORCHESTRATION_RUN_ID, clock: -> { ORCHESTRATION_FIXED_TIME },
        threaded_workflows: false
      )
      event = orchestrator.publish(
        type: "ProposalRejected", source: "test",
        payload: { "proposal_id" => "proposal_synthetic" }
      )
      job = orchestrator.jobs.list.find { |item| item.to_h.fetch("event_id") == event.id }
      assert_equal "succeeded", job.status
      execution_id = job.to_h.dig("result", "execution_id")
      original = orchestrator.history.fetch(execution_id)
      assert_equal "kg.orchestration.notify", original.steps.first.fetch("capability_id")
      assert_equal false, original.steps.first.dig("payload", "executable")
      assert_equal 1, orchestrator.notifications.list.length

      replayed = orchestrator.replay_execution(execution_id)
      assert_equal original.output_digest, replayed.output_digest
      assert_equal 1, orchestrator.notifications.list.length
    end
  end

  def test_default_gateway_doctor_and_declarative_workflows_load
    with_schema_vault do |root|
      orchestrator = KnowledgeOrchestration.build(
        vault_root: root, run_id: ORCHESTRATION_RUN_ID, clock: -> { ORCHESTRATION_FIXED_TIME },
        threaded_workflows: false
      )
      assert_equal 11, orchestrator.workflow_registry.list.length
      assert_equal 6, orchestrator.scheduler.schedules.length
      assert_includes KnowledgeOrchestration::EventRegistry.default.types, "GraphChanged"
    end
  end

  def test_engine_bridge_emits_graph_and_specific_events_only_for_real_changes
    with_schema_vault do |root|
      orchestrator = KnowledgeOrchestration.build(
        vault_root: root, run_id: ORCHESTRATION_RUN_ID, clock: -> { ORCHESTRATION_FIXED_TIME },
        threaded_workflows: false
      )
      engine = KnowledgeOrchestration::EngineEventBridge.new(
        event_bus: orchestrator.event_bus
      ).attach(KnowledgeGraph::Engine.new(
        vault_root: root, run_id: ORCHESTRATION_RUN_ID, clock: -> { ORCHESTRATION_FIXED_TIME }
      ))
      intent = KnowledgeGraph::CreateEntity.new(
        entity_type: "person", attributes: {
          id: "person_01K1D9VB96W7CS7F4M7K8Q2Z0A", name: "Synthetic Person",
          tier: "active", sensitivity: "private", data_origin: "public", is_self: true
        }
      )
      engine.execute(intent)
      engine.execute(intent)

      assert_equal %w[GraphChanged ContactCreated], orchestrator.event_bus.store.events.map(&:type)
    end
  end

  def test_plugin_registers_event_step_and_workflow_without_core_changes
    with_schema_vault do |root|
      orchestrator = KnowledgeOrchestration.build(
        vault_root: root, run_id: ORCHESTRATION_RUN_ID, clock: -> { ORCHESTRATION_FIXED_TIME },
        threaded_workflows: false
      )
      base = AgentPlatform::ManifestLoader.new.load(AgentPlatform::DEFAULT_MANIFEST_PATH).first
      data = base.public_contract
      data.delete("manifest_digest")
      data["capability_id"] = "plugin.synthetic.derive"
      data["name"] = "synthetic_derive"
      data["description"] = "Derive a synthetic plugin artifact."
      data["policy"]["permissions"] = []
      data["policy"]["approval"] = "none"
      data["execution"]["effects"] = "read_only"
      data["input_schema"] = {
        "type" => "object", "required" => ["value"],
        "properties" => { "value" => { "type" => "string" } },
        "additionalProperties" => false
      }
      data["output_schema"] = {
        "type" => "object", "required" => ["value"],
        "properties" => { "value" => { "type" => "string" } },
        "additionalProperties" => false
      }
      data["examples"] = [{ "arguments" => { "value" => "synthetic" } }]
      manifest = AgentPlatform::CapabilityManifest.new(data)
      workflow = KnowledgeOrchestration::WorkflowDefinition.new(
        id: "plugin_workflow", version: "1.0.0", on: ["PluginSignal"],
        steps: [{
          id: "derive", capability: "plugin.synthetic.derive",
          arguments: { "value" => "$event.payload.value" }
        }]
      )
      orchestrator.plugins.register_event("PluginSignal")
        .register_step(
          manifest: manifest,
          handler: lambda do |arguments, _context|
            AgentPlatform::HandlerResult.new(
              payload: { "value" => arguments.fetch("value") }, why: "Synthetic deterministic plugin."
            )
          end
        ).register_workflow(workflow)

      event = orchestrator.publish(type: "PluginSignal", source: "plugin:test", payload: { "value" => "ok" })
      job = orchestrator.jobs.list.find { |item| item.to_h.fetch("event_id") == event.id }
      assert_equal "succeeded", job.status
    end
  end
end
