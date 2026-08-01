# frozen_string_literal: true

require "json"
require_relative "test_support"

class KnowledgeActivityGoldenTest < Minitest::Test
  CASES = JSON.parse(File.read(File.expand_path("golden/cases.json", __dir__))).freeze

  def test_human_language_and_reverse_proposals_match_golden_scenarios
    CASES.each do |scenario|
      with_activity_vault do |root, engine, _orchestrator, timeline, set_time, _clock|
        create_person(engine)
        if %w[archive restore].include?(scenario.fetch("setup"))
          set_time.call(10)
          engine.execute(KnowledgeGraph::ArchiveEntity.new(
            entity_id: KnowledgeActivityTestSupport::PERSON_ID
          ))
        end
        if scenario.fetch("setup") == "restore"
          set_time.call(11)
          engine.execute(KnowledgeGraph::RestoreEntity.new(
            entity_id: KnowledgeActivityTestSupport::PERSON_ID
          ))
        end
        activity = timeline.call.latest
        assert_equal scenario.fetch("expected_type"), activity.type, scenario.fetch("name")
        assert_equal scenario.fetch("expected_summary"), activity.summary, scenario.fetch("name")

        response = timeline.call.create_proposal(activity.id, operation: :undo)
        proposal = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(response.fetch(:proposal))
        assert_equal scenario.fetch("expected_undo_intent"),
                     proposal.dig("planned_intents", 0, "intent", "type"), scenario.fetch("name")
      end
    end
  end
end
