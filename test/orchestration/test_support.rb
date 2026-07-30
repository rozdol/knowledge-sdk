# frozen_string_literal: true

require_relative "../test_helper"

module KnowledgeOrchestrationTestSupport
  ORCHESTRATION_FIXED_TIME = Time.new(2026, 7, 30, 7, 0, 0, "+03:00").freeze
  ORCHESTRATION_RUN_ID = "run_01KYS15D9P4HSK2C6PX1FXFNG6".freeze

  class FakeInvoker
    attr_reader :calls

    def initialize(failures: 0)
      @calls = []
      @failures = failures
    end

    def invoke(step, arguments, trace_id:)
      @calls << [step.id, arguments, trace_id]
      if @failures.positive?
        @failures -= 1
        raise KnowledgeOrchestration::WorkflowExecutionFailed, "synthetic retry"
      end
      {
        "payload" => { "value" => arguments.fetch("value", "ok"), "step" => step.id },
        "capability_version" => step.capability_version || "1.0.0",
        "duration_ms" => 1.0
      }
    end
  end

  def orchestration_event(type:, id_suffix: "1", payload: {})
    alphabet = id_suffix.to_s.rjust(26, "0")[-26, 26].tr("ILOU", "1234")
    KnowledgeOrchestration::Event.new(
      id: "event_#{alphabet}", timestamp: ORCHESTRATION_FIXED_TIME,
      source: "test", type: type, payload: payload,
      correlation_id: "correlation_test", causation_id: nil,
      trace_id: "trace_test", version: 1
    )
  end

  def cached_workflow(retries: 0)
    KnowledgeOrchestration::WorkflowDefinition.new(
      id: "cached_analysis", version: "1.0.0", on: ["ReminderDue"], outputs: {
        "value" => "$steps.analysis.payload.value"
      }, steps: [{
        id: "analysis", capability: "plugin.test.analysis@1.0.0",
        arguments: { "value" => "$event.payload.value" }, retries: retries,
        cache: {
          enabled: true, artifact_type: "analysis",
          invalidate_on: ["RelationshipUpdated", "GraphChanged"]
        }
      }]
    )
  end
end

class Minitest::Test
  include KnowledgeOrchestrationTestSupport
end
