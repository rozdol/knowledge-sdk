# frozen_string_literal: true

require "stringio"
require_relative "../test_helper"

class KnowledgeAnalysisIntegrationTest < Minitest::Test
  RUN_ID = "run_01KYYD4HNT4HEWNH1P3DQKTQ00"
  FIXED_TIME = Time.utc(2026, 8, 2, 10, 0, 0)

  def test_health_analysis_combines_datasets_graph_activity_and_explainability
    with_schema_vault do |root|
      orchestrator = KnowledgeOrchestration.build(
        vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME }, threaded_workflows: false
      )
      datasets = StructuredDataset::Engine.new(
        vault_root: root, run_id: RUN_ID, event_bus: orchestrator.event_bus, clock: -> { FIXED_TIME }
      )
      datasets.create("blood_tests")
      datasets.create("weight")
      6.times do |index|
        month = index + 2
        observed = format("2026-%02d-01T08:00:00Z", month)
        datasets.insert("blood_tests", { observed_at: observed, marker: "LDL", value: 100 + index * 5, unit: "mg/dL" })
        datasets.insert("weight", { observed_at: observed, weight_kg: 75 + index })
      end
      KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME }).execute(
        KnowledgeGraph::CreateEntity.new(
          entity_type: "project", attributes: {
            name: "LDL nutrition context", project_status: "active"
          }
        )
      )

      result = KnowledgeAnalysis::Engine.new(
        vault_root: root, dataset_engine: datasets, event_bus: orchestrator.event_bus,
        cache: orchestrator.cache, clock: -> { FIXED_TIME }
      ).analyze("Why has my LDL increased during the last six months?", as_of: "2026-08-02")
      analysis = result.fetch("analysis")
      assert_match(/LDL was increasing/, analysis.fetch("summary"))
      assert analysis.fetch("possible_factors").any? { |item| item.fetch("label").include?("weight") }
      assert analysis.fetch("possible_factors").all? { |item| item.fetch("causal") == false }
      assert_equal %w[blood_tests weight], analysis.fetch("datasets").map { |item| item.fetch("slug") }.sort
      refute_empty analysis.fetch("graph_evidence")
      refute_empty analysis.fetch("activity_evidence")
      refute_empty analysis.fetch("time_windows")
      refute_empty analysis.fetch("limitations")
      assert_equal false, analysis.dig("explainability", "causality_established")
      assert_equal false, analysis.dig("decision_trace", "decision_approved_is_executable")
      assert_equal 0, analysis.dig("decision_trace", "generated_intents")
      assert_includes analysis.fetch("subsystems"), "knowledge_cache"
      assert_includes analysis.fetch("subsystems"), "decision_engine"
      assert_includes analysis.fetch("analysis_modules").map { |item| item.fetch("name") }, "health"
      schema = JSON.parse(File.read(File.join(
        KnowledgeGraphTestSupport::SDK_ROOT, "docs/Dataset Intelligence/analysis-response.schema.json"
      )))
      assert AgentPlatform::SchemaValidator.new.validate!(
        schema, result, error_class: RuntimeError, label: "analysis response"
      )
    end
  end

  def test_finance_analysis_and_recommendation_proposal_activity
    with_schema_vault do |root|
      orchestrator = KnowledgeOrchestration.build(
        vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME }, threaded_workflows: false
      )
      datasets = StructuredDataset::Engine.new(
        vault_root: root, run_id: RUN_ID, event_bus: orchestrator.event_bus, clock: -> { FIXED_TIME }
      )
      datasets.create("expenses")
      datasets.create("subscriptions")
      [
        ["2026-03-01", 10], ["2026-04-01", 12], ["2026-05-01", 30], ["2026-06-01", 35]
      ].each do |date, amount|
        datasets.insert("expenses", {
          occurred_on: date, category: "Streaming", amount: amount,
          currency: "USD", merchant: "Synthetic Stream"
        })
      end
      datasets.insert("subscriptions", {
        service: "Synthetic Stream", amount: 24, currency: "USD",
        billing_period: "monthly", active: true
      })

      result = KnowledgeAnalysis::Engine.new(
        vault_root: root, dataset_engine: datasets, event_bus: orchestrator.event_bus,
        cache: orchestrator.cache, clock: -> { FIXED_TIME }
      ).analyze(
        "What subscriptions increased my monthly expenses?", as_of: "2026-08-02",
        propose_recommendations: true
      )
      analysis = result.fetch("analysis")
      assert_match(/Monthly recorded expenses/, analysis.fetch("summary"))
      assert analysis.fetch("possible_factors").any? { |item| item.fetch("label") == "Synthetic Stream" }
      proposal_id = analysis.dig("recommendations", 0, "proposal_id")
      refute_nil proposal_id
      proposal = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(proposal_id)
      assert_equal false, proposal.dig("model_metadata", "executable")
      assert_empty proposal.fetch("planned_intents")
      activity = KnowledgeActivity::Timeline.new(
        vault_root: root, event_bus: orchestrator.event_bus, cache: orchestrator.cache
      ).recent(limit: 20).find { |item| item.summary.include?("recommendation proposal") }
      refute_nil activity
      assert_equal proposal_id, activity.proposal
    end
  end

  def test_health_plugin_correlates_medication_adherence_with_sleep
    with_schema_vault do |root|
      datasets = StructuredDataset::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME })
      datasets.create("sleep")
      datasets.create("medication_log")
      durations = [5.0, 8.0, 5.5, 8.5]
      actions = %w[missed taken missed taken]
      4.times do |index|
        observed = "2026-0#{index + 4}-01T22:00:00Z"
        datasets.insert("sleep", {
          started_at: observed, duration_hours: durations[index], quality: index.odd? ? 4 : 2
        })
        datasets.insert("medication_log", {
          observed_at: observed, medication: "Syntheticine", action: actions[index]
        })
      end

      analysis = KnowledgeAnalysis::Engine.new(
        vault_root: root, dataset_engine: datasets, clock: -> { FIXED_TIME }
      ).analyze("Which medications correlate with improved sleep?", as_of: "2026-08-02").fetch("analysis")
      factor = analysis.fetch("possible_factors").find { |item| item.fetch("label") == "Syntheticine adherence" }
      refute_nil factor
      assert_includes factor.fetch("datasets"), "medication_log"
      assert_equal false, factor.fetch("causal")
    end
  end

  def test_analyze_cli_json_and_chat_routing
    with_schema_vault do |root|
      datasets = StructuredDataset::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME })
      datasets.create("weight")
      3.times do |index|
        datasets.insert("weight", {
          observed_at: "2026-0#{index + 5}-01T08:00:00Z", weight_kg: 80 + index
        })
      end
      decision = KnowledgeGraph::ChatIntentResolver.new.resolve("What changed shortly before my weight started increasing?")
      assert_equal "analyze", decision.route
      assert_equal "kg.analysis.run", decision.capability

      out = StringIO.new
      err = StringIO.new
      status = KnowledgeGraph::CLI.run(
        ["--vault", root, "--run-id", RUN_ID, "analyze", "What changed shortly before my weight started increasing?", "--as-of", "2026-08-02", "--json"],
        out: out, err: err, stdin: StringIO.new
      )
      assert_equal 0, status, err.string
      payload = JSON.parse(out.string)
      assert_equal "ok", payload.fetch("status")
      assert_equal "analysis.cross_knowledge", payload.dig("analysis", "intent")
      refute_match(/\e\[/, out.string)

      chat_out = StringIO.new
      chat_err = StringIO.new
      chat_status = KnowledgeGraph::CLI.run(
        ["--vault", root, "--run-id", RUN_ID, "chat", "--text", "What changed shortly before my weight started increasing?", "--json", "--explain"],
        out: chat_out, err: chat_err, stdin: StringIO.new
      )
      assert_equal 0, chat_status, chat_err.string
      chat = JSON.parse(chat_out.string)
      assert_equal "analyze", chat.fetch("route")
      assert_equal "kg.analysis.run", chat.dig("explain", "capability")
      assert_equal "analysis.cross_knowledge", chat.dig("result", "analysis", "intent")
    end
  end

  def test_restricted_datasets_and_graph_records_are_excluded_from_analysis
    with_schema_vault do |root|
      datasets = StructuredDataset::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME })
      datasets.create("blood_tests", sensitivity: "restricted")
      datasets.insert("blood_tests", {
        observed_at: "2026-07-01T08:00:00Z", marker: "LDL", value: 120, unit: "mg/dL"
      })
      result = KnowledgeAnalysis::Engine.new(
        vault_root: root, dataset_engine: datasets, clock: -> { FIXED_TIME }
      ).analyze("Why has my LDL increased?", as_of: "2026-08-02")
      analysis = result.fetch("analysis")
      refute_includes analysis.fetch("datasets").map { |item| item.fetch("slug") }, "blood_tests"
      restricted_id = datasets.describe("blood_tests").fetch("dataset_id")
      refute analysis.fetch("graph_evidence").any? { |item| item["record_id"] == restricted_id }
    end
  end
end
