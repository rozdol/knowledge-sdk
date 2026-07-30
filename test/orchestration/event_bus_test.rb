# frozen_string_literal: true

require_relative "test_support"

class OrchestrationEventBusTest < Minitest::Test
  def test_publish_filter_replay_versioning_and_dead_letters
    with_vault do |root|
      store = KnowledgeOrchestration::EventStore.new(vault_root: root)
      dead_letters = KnowledgeOrchestration::DeadLetterStore.new(vault_root: root, clock: -> { ORCHESTRATION_FIXED_TIME })
      bus = KnowledgeOrchestration::EventBus.new(
        store: store, vault_root: root, dead_letters: dead_letters, clock: -> { ORCHESTRATION_FIXED_TIME }
      )
      received = []
      bus.subscribe(
        id: "collector",
        filter: KnowledgeOrchestration::EventFilter.new(types: ["ReminderDue"])
      ) { |event, replay:| received << [event.id, replay] }
      first = bus.publish(type: "ReminderDue", source: "test", payload: { "kind" => "goal" })
      second = bus.publish(type: "DeadlineReached", source: "test", payload: {})

      assert_equal [1, 2], [first.sequence, second.sequence]
      assert_equal [first.id], bus.filter(types: ["ReminderDue"]).map(&:id)
      bus.replay(first.id)
      assert_equal [[first.id, false], [first.id, true]], received

      bus.subscribe(id: "failing") { |_event, replay:| raise "synthetic failure #{replay}" }
      bus.publish(type: "ReminderDue", source: "test", payload: {})
      letter = dead_letters.list.last
      assert_equal "failing", letter.fetch("subscriber_id")
      assert_equal true, letter.fetch("replayable")

      assert_raises(KnowledgeOrchestration::UnsupportedEventVersion) do
        bus.publish(type: "ReminderDue", source: "test", payload: {}, version: 2)
      end
    end
  end

  def test_events_are_deeply_immutable
    payload = { "nested" => { "items" => ["a"] } }
    event = orchestration_event(type: "ReminderDue", payload: payload)
    payload.fetch("nested").fetch("items") << "b"

    assert_equal ["a"], event.payload.dig("nested", "items")
    assert event.frozen?
    assert event.payload.frozen?
    assert event.payload.dig("nested", "items").frozen?
  end
end
