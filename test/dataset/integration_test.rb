# frozen_string_literal: true

require_relative "test_support"

class StructuredDatasetIntegrationTest < Minitest::Test
  def test_search_planning_activity_and_events_consume_dataset_without_sql_reasoning
    with_schema_vault do |root|
      create_self(root)
      orchestrator = KnowledgeOrchestration.build(
        vault_root: root, run_id: RUN_ID, actor_id: "dataset-test", threaded_workflows: false,
        clock: -> { FIXED_TIME }
      )
      engine = dataset_engine(root, event_bus: orchestrator.event_bus)
      engine.create("weight")
      engine.insert("weight", { observed_at: "2026-07-01T10:00:00Z", weight_kg: 82 }, source: "scale")
      engine.insert("weight", { observed_at: "2026-08-01T10:00:00Z", weight_kg: 80 }, source: "scale")

      search = StructuredDataset::Search.new(engine: engine).query("Show my weight trend")
      assert_equal "dataset_trend", search.fetch("kind")
      assert_equal 2, search.fetch("answers").length

      signals = StructuredDataset::PlanningAdapter.new(engine: engine).signals
      signal = signals.find { |item| item["metric"] == "weight_kg" }
      assert_equal(-2.0, signal.fetch("absolute_change"))
      assert_equal "none", signal.fetch("interpretation")

      events = orchestrator.event_bus.store.events.select { |item| item.type == "DatasetChanged" }
      assert_equal "insert", events.last.payload.fetch("action")
      activity = KnowledgeActivity::Timeline.new(
        vault_root: root, event_bus: orchestrator.event_bus, cache: orchestrator.cache
      ).recent(limit: 10).find { |item| item.summary.include?("received a row") }
      refute_nil activity
      activity_event = events.find { |event| activity.events.include?(event.id) }
      refute_nil activity_event
      assert_equal "insert", activity_event.payload.fetch("action")
    end
  end

  def test_observation_proposal_approval_and_submission_insert_a_traceable_private_row
    with_schema_vault do |root|
      create_self(root)
      dataset_engine(root).create("blood_pressure")

      status, output, errors = run_cli(
        root, "observe", "--text", "My blood pressure today was 128 over 81 with pulse 64.",
        "--timestamp", "2026-08-01T10:00:00Z", "--source", "hermes", "--json"
      )
      assert_equal 0, status, errors
      proposal_id = JSON.parse(output).dig("proposals", 0, "id")
      refute_nil proposal_id
      proposal = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(proposal_id)
      planned = proposal.fetch("planned_intents").first
      assert_equal "InsertDatasetRow", planned.dig("intent", "type")
      assert_equal "human_review", planned.fetch("approval_requirement")

      status, approval_output, errors = run_cli(root, "proposal", "approve", proposal_id, "--all", "--actor", "human-test")
      assert_equal 0, status, errors
      approval_id = JSON.parse(approval_output).fetch("approval_id")
      status, submission_output, errors = run_cli(root, "proposal", "submit", proposal_id)
      assert_equal 0, status, errors
      assert_equal "executed", JSON.parse(submission_output).fetch("status")

      row = dataset_engine(root).query("blood_pressure").first
      assert_equal 128, row.fetch("systolic")
      assert_equal 81, row.fetch("diastolic")
      assert_equal 64, row.fetch("pulse")
      assert_equal proposal_id, row.fetch("proposal_id")
      assert_equal approval_id, row.fetch("approval_id")
      status, replay_output, errors = run_cli(root, "proposal", "submit", proposal_id)
      assert_equal 0, status, errors
      assert JSON.parse(replay_output).dig("results", 0, "replayed")
      assert_equal 1, dataset_engine(root).stats("blood_pressure").fetch("row_count")
      graph_text = Dir.glob(File.join(root, "Datasets/*.md")).map { |path| File.read(path) }.join
      refute_includes graph_text, "128"
      refute_includes graph_text, "81"
    end
  end

  def test_chat_routes_dataset_questions_through_safe_gateway_capability
    with_schema_vault do |root|
      create_self(root)
      engine = dataset_engine(root)
      engine.create("blood_tests")
      engine.insert(
        "blood_tests", { observed_at: "2026-08-01T09:00:00Z", marker: "Hemoglobin", value: 14.1, unit: "g/dL" },
        source: "synthetic-lab"
      )

      status, output, errors = run_cli(
        root, "chat", "--text", "What was my latest hemoglobin?", "--json", "--explain"
      )
      assert_equal 0, status, errors
      payload = JSON.parse(output)
      assert_equal "kg.datasets.query", payload.dig("explain", "capability")
      assert_equal 14.1, payload.dig("result", "answers", 0, "value")
    end
  end
end
