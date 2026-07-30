# frozen_string_literal: true

require_relative "test_support"

class OrchestrationPerformanceTest < Minitest::Test
  def test_event_bus_handles_bounded_batch
    with_vault do |root|
      bus = KnowledgeOrchestration::EventBus.new(
        store: KnowledgeOrchestration::EventStore.new(vault_root: root),
        vault_root: root, clock: -> { ORCHESTRATION_FIXED_TIME }
      )
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      200.times { |index| bus.publish(type: "ReminderDue", source: "performance", payload: { "index" => index }) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal 200, bus.store.events.length
      assert_operator elapsed, :<, 5.0
    end
  end
end
