# frozen_string_literal: true

require_relative "test_support"

class OrchestrationSchedulerTest < Minitest::Test
  def test_cron_and_scheduler_are_deterministic_and_idempotent_per_slot
    with_vault do |root|
      store = KnowledgeOrchestration::EventStore.new(vault_root: root)
      bus = KnowledgeOrchestration::EventBus.new(store: store, vault_root: root, clock: -> { ORCHESTRATION_FIXED_TIME })
      schedule = KnowledgeOrchestration::ScheduleDefinition.new(
        id: "morning", cron: "0 7 * * *", event_type: "DigestRequested",
        workflow: "digest_requested", payload: { "period" => "daily" }
      )
      scheduler = KnowledgeOrchestration::Scheduler.new(
        schedules: [schedule], event_bus: bus, vault_root: root, clock: -> { ORCHESTRATION_FIXED_TIME }
      )

      first = scheduler.run(at: ORCHESTRATION_FIXED_TIME)
      second = scheduler.run(at: ORCHESTRATION_FIXED_TIME)
      assert_equal 1, first.length
      assert_empty second
      assert_equal "2026-07-30", first.first.payload.fetch("as_of")
      assert_equal "digest_requested", first.first.payload.fetch("_workflow")
      assert_empty scheduler.due(at: ORCHESTRATION_FIXED_TIME + 60)
    end
  end

  def test_cron_supports_ranges_lists_and_steps
    cron = KnowledgeOrchestration::CronExpression.new("*/15 7-9 * * 1,3,5")
    assert cron.match?(Time.new(2026, 7, 31, 8, 30, 0, "+03:00"))
    refute cron.match?(Time.new(2026, 7, 31, 8, 31, 0, "+03:00"))
  end
end
