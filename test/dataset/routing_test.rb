# frozen_string_literal: true

require_relative "test_support"

class StructuredDatasetRoutingTest < Minitest::Test
  class InsertProteinMeasurement < KnowledgeGraph::DatasetIntent
    field :observed_at
    field :protein_g
  end

  EXAMPLES = [
    {
      text: "I take Berberine every morning",
      classifier: "dataset.medication_schedule", intent: "ReplaceMedicationSchedule",
      dataset: "medication_schedules"
    },
    {
      text: "Today's blood pressure was 128 over 81",
      classifier: "dataset.blood_pressure_measurement", intent: "InsertBloodPressureMeasurement",
      dataset: "blood_pressure"
    },
    {
      text: "My weight is 82.3 kg",
      classifier: "dataset.weight_measurement", intent: "InsertWeightMeasurement",
      dataset: "weight"
    },
    {
      text: "Today's LDL is 110",
      classifier: "dataset.blood_test_result", intent: "InsertBloodTestResult",
      dataset: "blood_tests"
    }
  ].freeze

  def test_classifier_uses_declared_route_priority_and_supports_plugin_registration
    resolver = KnowledgeGraph::ChatIntentResolver.new
    assert_equal "dataset", resolver.resolve("My weight is 82.3 kg").route
    assert_equal "observe", resolver.resolve("Ivan Petrov works at Microsoft.").route
    assert_equal "search", resolver.resolve("Who is Ivan Petrov?").route
    assert_equal "plan", resolver.resolve("Create a plan for Ivan.").route
    assert_equal "proposal", resolver.resolve("Show pending proposals.").route
    protected = resolver.resolve("Мой вес сегодня 82 кг")
    assert_equal "dataset", protected.route
    assert_equal "dataset.structured_observation", protected.intent

    classifier = KnowledgeSDK::IntentClassifier.new
    classifier.register(name: "nutrition-plugin", route: "dataset") do |text, _context|
      next nil unless text == "Breakfast contained 30 g protein"

      {
        "intent" => "dataset.nutrition", "confidence" => 0.93,
        "reason" => "plugin-owned structured nutrition observation"
      }
    end
    classifier.register(name: "nutrition-low-confidence", route: "dataset") do |text, _context|
      next nil unless text == "Breakfast contained 30 g protein"

      {
        "intent" => "dataset.generic_food", "confidence" => 0.60,
        "reason" => "lower-confidence overlapping plugin"
      }
    end
    classification = classifier.classify("Breakfast contained 30 g protein")
    assert_equal "dataset.nutrition", classification.intent
    assert_equal 0.93, classification.confidence

    registry = StructuredDataset::RoutingRegistry.new
    registry.register(
      intent: "dataset.nutrition", dataset: "nutrition",
      intent_class: InsertProteinMeasurement,
      builder: ->(common, slots) { InsertProteinMeasurement.new(**common.merge(slots)) },
      writer: ->(_engine, _intent, _provenance) { raise "not executed in registry test" }
    )
    rebuilt = KnowledgeGraph::IntentFactory.build(
      "type" => "InsertProteinMeasurement",
      "params" => {
        "source" => "test", "observation_id" => "observation_test",
        "observed_at" => "2026-08-02T09:30:00Z", "protein_g" => 30
      }
    )
    assert_instance_of InsertProteinMeasurement, rebuilt
    assert_equal "nutrition", registry.fetch("dataset.nutrition").dataset
  end

  def test_chat_creates_named_dataset_intents_without_graph_extraction
    with_schema_vault do |root|
      engine = dataset_engine(root)
      EXAMPLES.map { |example| example.fetch(:dataset) }.uniq.each { |dataset| engine.create(dataset) }
      before = KnowledgeIntelligence::GraphSnapshot.load(vault_root: root).digest
      proposal_ids = []

      EXAMPLES.each do |example|
        status, output, errors = run_cli(
          root, "chat", "--text", example.fetch(:text),
          "--timestamp", "2026-08-02T09:30:00Z", "--json", "--explain"
        )
        assert_equal 0, status, errors
        assert_empty errors
        payload = JSON.parse(output)
        assert_equal "dataset", payload.fetch("route")
        assert_equal "kg.datasets.propose", payload.dig("explain", "capability")
        assert_equal example.fetch(:classifier), payload.dig("explain", "intent")
        assert_operator payload.dig("explain", "confidence"), :>=, 0.90

        proposal_id = payload.dig("result", "proposal_id")
        proposal_ids << proposal_id
        proposal = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(proposal_id)
        assert_equal "intent-classifier", proposal.dig("model_metadata", "provider")
        assert_equal "dataset-routing-v1", proposal.fetch("pipeline_version")
        assert_equal example.fetch(:intent), proposal.dig("planned_intents", 0, "intent", "type")
        assert_equal "human_review", proposal.dig("planned_intents", 0, "approval_requirement")
      end

      assert_equal before, KnowledgeIntelligence::GraphSnapshot.load(vault_root: root).digest
      event_types = KnowledgeOrchestration::EventStore.new(vault_root: root).events.map(&:type)
      assert_includes event_types, "ProposalCreated"
      refute_includes event_types, "ExtractionCompleted"

      proposal_ids.each do |proposal_id|
        status, _output, errors = run_cli(
          root, "proposal", "approve", proposal_id, "--all", "--actor", "routing-test"
        )
        assert_equal 0, status, errors
        status, output, errors = run_cli(root, "proposal", "submit", proposal_id)
        assert_equal 0, status, errors
        submission = JSON.parse(output)
        assert_equal "executed", submission.fetch("status"), submission.inspect
        assert_match(/\Aaudit_/, submission.dig("results", 0, "audit_id"))
        assert_match(/\Adataevt_/, submission.dig("results", 0, "dataset_activity_id"))
      end

      assert_equal "Berberine", engine.query("medication_schedules").first.fetch("medication")
      assert_equal 128, engine.query("blood_pressure").first.fetch("systolic")
      assert_equal 82.3, engine.query("weight").first.fetch("weight_kg")
      assert_equal "LDL", engine.query("blood_tests").first.fetch("marker")
      assert_equal "unspecified", engine.query("blood_tests").first.fetch("unit")

      activity = KnowledgeActivity::Timeline.new(vault_root: root).recent(limit: 20).find do |item|
        proposal_ids.include?(item.proposal) && item.summary.include?("received a row")
      end
      refute_nil activity
      refute_empty activity.events
      dataset_events = KnowledgeOrchestration::EventStore.new(vault_root: root).events.select do |event|
        event.type == "DatasetChanged" && proposal_ids.include?(event.payload["proposal_id"])
      end
      assert_equal 4, dataset_events.length
      graph_text = Dir.glob(File.join(root, "Datasets/*.md")).map { |path| File.read(path) }.join
      %w[Berberine 128 82.3 LDL].each { |value| refute_includes graph_text, value }
    end
  end

  def test_structured_table_is_kept_out_of_graph_extraction_when_schema_is_ambiguous
    with_schema_vault do |root|
      status, output, errors = run_cli(
        root, "chat", "--text", "date,amount,currency\n2026-08-01,20,USD", "--json", "--explain"
      )
      assert_equal 0, status, errors
      assert_empty errors
      payload = JSON.parse(output)
      assert_equal "dataset", payload.fetch("route")
      assert_equal "clarification_required", payload.fetch("status")
      assert_equal "dataset.structured_observation", payload.dig("explain", "intent")
      refute Dir.exist?(File.join(root, KnowledgeExtraction::ProposalStore::RUNTIME, "proposals"))
    end
  end

  def test_dataset_engine_handler_refuses_an_unapproved_intent
    with_schema_vault do |root|
      datasets = dataset_engine(root)
      datasets.create("weight")
      engine = KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID)
      StructuredDataset::IntentHandler.new(
        dataset_engine: datasets, proposal_id: "proposal_01KYYD4HNT4HEWNH1P3DQKTPPG"
      ).attach(engine)
      intent = KnowledgeGraph::InsertWeightMeasurement.new(
        observed_at: "2026-08-02T09:30:00Z", weight_kg: 82.3,
        source: "test", observation_id: "observation_01KYYD4HNT4HEWNH1P3DQKTPPH"
      )

      assert_raises(KnowledgeGraph::ApprovalRequired) { engine.execute(intent) }
      assert_empty datasets.query("weight")
    end
  end

  def test_dataset_write_is_deferred_until_after_engine_validation
    with_schema_vault do |root|
      datasets = dataset_engine(root)
      datasets.create("weight")
      engine = KnowledgeGraph::Engine.new(
        vault_root: root, run_id: RUN_ID,
        validator: ->(_context) { raise KnowledgeGraph::ValidationError, "synthetic failure" }
      )
      StructuredDataset::IntentHandler.new(
        dataset_engine: datasets, proposal_id: "proposal_01KYYD4HNT4HEWNH1P3DQKTPPJ",
        approval: {
          "approval_id" => "approval_01KYYD4HNT4HEWNH1P3DQKTPPK", "actor_id" => "human-test"
        }
      ).attach(engine)
      intent = KnowledgeGraph::InsertWeightMeasurement.new(
        observed_at: "2026-08-02T09:30:00Z", weight_kg: 82.3,
        source: "test", observation_id: "observation_01KYYD4HNT4HEWNH1P3DQKTPPM"
      )

      assert_raises(KnowledgeGraph::ValidationError) { engine.execute(intent) }
      assert_empty datasets.query("weight")
    end
  end
end
