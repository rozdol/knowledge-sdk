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
      classifier: "dataset.medication_schedule.create", intent: "CreateMedicationSchedule",
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

  def test_classifier_uses_domain_plugins_confidence_and_graph_last_resort
    resolver = KnowledgeGraph::ChatIntentResolver.new
    assert_equal "dataset", resolver.resolve("My weight is 82.3 kg").route
    graph_fallback = resolver.resolve("Ivan Petrov works at Microsoft.")
    assert_equal "observe", graph_fallback.route
    assert_equal 0.20, graph_fallback.confidence
    assert_includes graph_fallback.reason, "last resort"
    assert_equal "search", resolver.resolve("Who is Ivan Petrov?").route
    assert_equal "plan", resolver.resolve("Create a plan for Ivan.").route
    assert_equal "proposal", resolver.resolve("Show pending proposals.").route
    protected = resolver.resolve("Мой вес сегодня 82 кг")
    assert_equal "dataset", protected.route
    assert_equal "dataset.weight_measurement", protected.intent

    classifier = KnowledgeSDK::IntentClassifier.new
    classifier.register(name: "nutrition-plugin", domain: "health", route: "dataset") do |text, _context|
      next nil unless text == "Breakfast contained 30 g protein"

      {
        "intent" => "dataset.nutrition", "confidence" => 0.93,
        "explanation" => "plugin-owned structured nutrition observation"
      }
    end
    classifier.register(name: "nutrition-low-confidence", domain: "health", route: "dataset") do |text, _context|
      next nil unless text == "Breakfast contained 30 g protein"

      {
        "intent" => "dataset.generic_food", "confidence" => 0.60,
        "explanation" => "lower-confidence overlapping plugin"
      }
    end
    classifier.register(name: "finance-not-applicable", domain: "finance", route: "dataset") do |text, _context|
      next nil unless text == "Breakfast contained 30 g protein"

      {
        "intent" => "dataset.expense", "confidence" => 1.0,
        "explanation" => "synthetic classifier from the losing domain"
      }
    end
    classification = classifier.classify("Breakfast contained 30 g protein")
    assert_equal "dataset.nutrition", classification.intent
    assert_equal 0.93, classification.confidence
    assert_equal "health", classification.domain
    assert_equal "plugin-owned structured nutrition observation", classification.explanation

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

  def test_structured_health_observations_route_by_semantics_in_english_russian_and_greek
    examples = {
      "en" => {
        "I take Berberine 500 mg every morning" => "dataset.medication_schedule.create",
        "My blood pressure is 128/81 with pulse 64" => "dataset.blood_pressure_measurement",
        "My weight is 82.3 kg" => "dataset.weight_measurement",
        "My LDL is 110 mg/dL" => "dataset.blood_test_result",
        "My waist is 84 cm" => "dataset.body_measurement"
      },
      "ru" => {
        "Я принимаю метформин 500 мг каждое утро" => "dataset.medication_schedule.create",
        "Моё давление сегодня 128/81, пульс 64" => "dataset.blood_pressure_measurement",
        "Мой вес сегодня 82,3 кг" => "dataset.weight_measurement",
        "ЛПНП: 110 мг/дл" => "dataset.blood_test_result",
        "Обхват талии: 84 см" => "dataset.body_measurement"
      },
      "el" => {
        "Παίρνω μετφορμίνη 500 mg κάθε πρωί" => "dataset.medication_schedule.create",
        "Η πίεσή μου σήμερα ήταν 128/81 με σφυγμό 64" => "dataset.blood_pressure_measurement",
        "Το βάρος μου σήμερα είναι 82,3 κιλά" => "dataset.weight_measurement",
        "LDL: 110 mg/dL" => "dataset.blood_test_result",
        "Η μέση μου είναι 84 cm" => "dataset.body_measurement"
      }
    }
    classifier = KnowledgeGraph::ChatIntentResolver.classifier

    examples.each do |language, observations|
      observations.each do |text, intent|
        domain = classifier.detect_domain(text)
        classification = classifier.classify(text, "captured_at" => "2026-08-02T09:30:00Z")
        assert_equal "health", domain.domain, "#{language}: #{text}"
        assert_equal "health", classification.domain, "#{language}: #{text}"
        assert_equal "dataset", classification.route, "#{language}: #{text}"
        assert_equal intent, classification.intent, "#{language}: #{text}"
        refute_equal "graph.observe", classification.intent, "#{language}: #{text}"
      end
    end

    guarded = [
      "Body temperature is 38 °C",
      "Температура тела 38,2 °C",
      "Ο κορεσμός οξυγόνου είναι 98%"
    ]
    guarded.each do |text|
      classification = classifier.classify(text)
      assert_equal "health", classification.domain, text
      assert_equal "dataset", classification.route, text
      assert_equal "dataset.structured_observation", classification.intent, text
      refute_equal "graph.observe", classification.intent, text
    end
  end

  def test_semantic_domain_detection_covers_every_supported_domain
    classifier = KnowledgeSDK::IntentClassifier.new
    examples = {
      "health" => "My glucose is 95 mg/dL",
      "finance" => "I paid €20 for the subscription",
      "crm" => "Follow up with the customer contact",
      "trading" => "Place a limit order for the stock",
      "knowledge" => "Show me the project notes",
      "generic" => "A quiet afternoon under clear skies"
    }

    examples.each do |domain, text|
      assert_equal domain, classifier.detect_domain(text).domain, text
    end
  end

  def test_classifier_text_normalization_is_utf8_unicode_safe_and_preserves_names
    normalized = KnowledgeSDK::ClassifierTextNormalizer.new.normalize(
      "ПРИЁМ Berberine, B12 и zinc carnosine\r\nвечером"
    )

    assert_equal Encoding::UTF_8, normalized.original.encoding
    assert_equal "ПРИЁМ Berberine, B12 и zinc carnosine\nвечером", normalized.original
    assert_equal "прием berberine, b12 и zinc carnosine\nвечером", normalized.matching
  end

  def test_common_russian_medication_forms_are_bounded_schedule_signals
    examples = [
      "Принимать zinc carnosine по 1 таблетке утром",
      "Она принимает B12 500 мкг днем под язык",
      "Приём Berberine: 1 капсула вечером после еды",
      "Пью витамин D 2 капли раз в день",
      "Выпиваю магний 1 таблетку на ночь",
      "Я принимаю цинк 10 мг до еды",
      "Я принимаю средство 1 таблетку сублингвально утром"
    ]
    classifier = KnowledgeGraph::ChatIntentResolver.classifier

    examples.each do |text|
      classification = classifier.classify(text, "captured_at" => "2026-08-02T09:30:00Z")
      assert_equal "dataset", classification.route, text
      assert_equal "dataset.medication_schedule.create", classification.intent, text
      assert_operator classification.confidence, :>=, 0.90, text
    end
  end

  def test_real_chat_cli_routes_multilingual_medication_schedules_to_dataset
    examples = [
      "I take Berberine every morning on an empty stomach.",
      "Я принимаю утром натощак Berberine 1 капсулу.",
      "Παίρνω Berberine κάθε πρωί με άδειο στομάχι."
    ]

    with_schema_vault do |root|
      datasets = dataset_engine(root)
      datasets.create("medication_schedules")
      before = KnowledgeIntelligence::GraphSnapshot.load(vault_root: root).digest

      examples.each do |text|
        status, output, errors = run_cli(
          root, "chat", "--text", text,
          "--timestamp", "2026-08-02T09:30:00Z", "--json", "--explain"
        )
        assert_equal 0, status, errors
        assert_empty errors
        payload = JSON.parse(output)
        assert_equal "ok", payload.fetch("status")
        assert_equal "dataset", payload.fetch("route")
        assert_equal "dataset.medication_schedule.create", payload.dig("explain", "intent")
        assert_equal "dataset.medication_schedule.create", payload.dig("explain", "selected_intent")
        assert_kind_of String, payload.dig("explain", "normalized_text")
        health_domain = payload.dig("explain", "domain_candidates").find do |item|
          item["domain"] == "health"
        end
        refute_nil health_domain
        assert_operator health_domain.fetch("confidence"), :>=, 0.90
        assert_includes payload.dig("explain", "loaded_classifier_plugins"),
                        "structured-dataset-health"
        candidate = payload.dig("explain", "intent_candidates").find do |item|
          item["intent"] == "dataset.medication_schedule.create"
        end
        refute_nil candidate
        assert_operator candidate.fetch("confidence"), :>=, 0.90
        refute payload.dig("explain", "intent_candidates").any? { |item|
          item["intent"] == "graph.observe"
        }
        if text.start_with?("Я")
          assert_equal "я принимаю утром натощак berberine 1 капсулу.",
                       payload.dig("explain", "normalized_text")
        end
        assert_equal "dataset.medication_schedule.create", payload.dig("result", "intent")
        assert_equal "dataset_update", payload.dig("result", "proposal", "type")
        assert_equal "awaiting_approval", payload.dig("result", "proposal", "status")
        refute payload.fetch("result").key?("observation_id")

        proposal = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(
          payload.dig("result", "proposal_id")
        )
        assert_equal "intent-classifier", proposal.dig("model_metadata", "provider")
        assert_equal "CreateMedicationSchedule",
                     proposal.dig("planned_intents", 0, "intent", "type")
      end

      assert_empty datasets.query("medication_schedules")
      assert_equal before, KnowledgeIntelligence::GraphSnapshot.load(vault_root: root).digest
      event_types = KnowledgeOrchestration::EventStore.new(vault_root: root).events.map(&:type)
      refute_includes event_types, "ExtractionCompleted"
    end
  end

  def test_real_chat_cli_parses_multiline_russian_schedule_without_writing
    text = <<~TEXT
      Я принимаю утром натощак:
      Berberine 1 капсулу
      zinc carnosine 1 капсулу
      taurine 1 капсулу.

      Днем я принимаю витамин B12 под язык и еще 1 капсулу Berberine
    TEXT

    with_schema_vault do |root|
      datasets = dataset_engine(root)
      datasets.create("medication_schedules")
      status, output, errors = run_cli(
        root, "chat", "--text", text,
        "--timestamp", "2026-08-02T09:30:00Z", "--json", "--explain"
      )
      assert_equal 0, status, errors
      assert_empty errors
      payload = JSON.parse(output)
      assert_equal "dataset", payload.fetch("route")
      assert_equal "dataset.medication_schedule.create", payload.dig("explain", "selected_intent")

      entries = payload.dig("result", "classification", "slots", "entries")
      assert_equal 5, entries.length
      berberine = entries.select { |entry| entry["medication"] == "Berberine" }
      assert_equal %w[every\ morning every\ afternoon], berberine.map { |entry| entry["schedule"] }
      morning = entries.select { |entry| entry["schedule"] == "every morning" }
      assert_equal 3, morning.length
      assert morning.all? { |entry| entry["fasting"] == true }
      b12 = entries.find { |entry| entry["medication"].include?("B12") }
      assert_equal "sublingual", b12.fetch("administration_route")
      assert_equal 5, payload.dig("result", "parsed_entry_count")
      assert_equal "dataset_update", payload.dig("result", "proposal", "type")
      refute payload.fetch("result").key?("observation_id")

      proposal = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(
        payload.dig("result", "proposal_id")
      )
      planned = proposal.fetch("planned_intents")
      assert_equal 5, planned.length
      assert planned.all? { |item| item.dig("intent", "type") == "CreateMedicationSchedule" }
      berberine_intents = planned.select do |item|
        item.dig("intent", "params", "medication") == "Berberine"
      end
      assert_equal 2, berberine_intents.length
      berberine_times = berberine_intents.map do |item|
        item.dig("intent", "params", "schedule_json", "times", 0, "time_of_day")
      end
      assert_equal %w[morning day], berberine_times
      assert_empty datasets.query("medication_schedules")
      event_types = KnowledgeOrchestration::EventStore.new(vault_root: root).events.map(&:type)
      refute_includes event_types, "ExtractionCompleted"
    end
  end

  def test_medication_administration_event_requests_structured_clarification
    with_schema_vault do |root|
      status, output, errors = run_cli(
        root, "chat", "--text", "Сегодня в 08:00 я принял Berberine",
        "--timestamp", "2026-08-02T09:30:00Z", "--json", "--explain"
      )
      assert_equal 0, status, errors
      assert_empty errors
      payload = JSON.parse(output)
      assert_equal "clarification_required", payload.fetch("status")
      assert_equal "dataset", payload.fetch("route")
      assert_equal "dataset.structured_observation", payload.dig("explain", "intent")
      assert_includes payload.dig("clarification", "question"), "medication administration event"
      refute Dir.exist?(File.join(root, KnowledgeExtraction::ProposalStore::RUNTIME, "proposals"))
    end
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
