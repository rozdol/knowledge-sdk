# frozen_string_literal: true

require_relative "test_support"

class KnowledgeActivityTimelineTest < Minitest::Test
  def test_latest_recent_date_search_explain_and_diff_are_activity_projections
    with_activity_vault do |_root, engine, orchestrator, timeline, set_time, _clock|
      create_person(engine)
      created = timeline.call.latest

      set_time.call(10)
      engine.execute(KnowledgeGraph::UpdateEntity.new(
        entity_id: KnowledgeActivityTestSupport::PERSON_ID, changes: { pronouns: "she/her" }
      ))
      history = timeline.call
      latest = history.latest

      assert_equal "knowledge_changed", latest.type
      assert_equal "Ada Lovelace was updated.", latest.summary
      assert_equal "alex", latest.actor
      assert_equal 2, history.recent(limit: 20).length
      assert_equal 2, history.today.length
      assert_equal 1, history.since(time: "2026-08-01T09:30:00+03:00").length
      assert_equal 2, history.between(
        from_time: "2026-08-01T08:00:00+03:00", to_time: "2026-08-01T10:30:00+03:00"
      ).length
      assert_equal [latest.id], history.search(query: "Ada Lovelace", limit: 1).map(&:id)

      explanation = history.explain(latest.id)
      assert_equal "ok", explanation.fetch(:status)
      assert_equal "success", explanation.dig(:explanation, :execution, :status)
      refute_empty explanation.dig(:explanation, :origin, :event_references)
      assert_match(/\A[0-9a-f]{64}\z/, explanation.dig(:explanation, :resulting_changes, :current_snapshot))

      diff = history.diff(from: created.id, to: latest.id)
      assert_equal 1, diff.dig(:changes, :count)
      assert_equal [KnowledgeActivityTestSupport::PERSON_ID], diff.dig(:changes, :changed)
      assert_match(/\A[0-9a-f]{64}\z/, diff.dig(:to, :state_digest))

      assert timeline.call.recent(limit: 1)
      assert_operator orchestrator.cache.hits, :>, 0
      assert orchestrator.cache.list.any? { |artifact| artifact.artifact_type == "activity" }
    end
  end

  def test_restricted_activity_is_redacted_from_listing_search_and_explanation
    with_activity_vault do |_root, engine, _orchestrator, timeline, set_time, _clock|
      create_person(engine)
      set_time.call(10)
      engine.execute(
        KnowledgeGraph::CreateEntity.new(
          entity_type: "organization",
          attributes: {
            id: KnowledgeActivityTestSupport::ORG_ID, name: "Project Nightjar", org_kind: "company",
            sensitivity: "restricted", data_origin: "public"
          }
        )
      )

      history = timeline.call
      activity = history.latest
      assert_equal "redacted", activity.privacy
      assert_equal "A restricted knowledge change was recorded.", activity.summary
      assert_empty activity.affected_objects
      assert_empty history.search(query: "Nightjar")
      assert_equal [{ redacted: true }], history.explain(activity.id).dig(:explanation, :evidence)
    end
  end
end
