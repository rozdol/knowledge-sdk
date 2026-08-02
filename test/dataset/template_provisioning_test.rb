# frozen_string_literal: true

require_relative "test_support"

class StructuredDatasetTemplateProvisioningTest < Minitest::Test
  LAB_REPORT = <<~TEXT.freeze
    CLINICAL LABORATORY REPORT
    Test Date: 2026-07-30
    Panel: Lipid and Iron
    Specimen: Serum
    Laboratory: Synthetic Diagnostics
    LDL Cholesterol 128 mg/dL 0-100 H
    Ferritin 42 ng/mL 15-150
  TEXT

  def test_builtin_template_discovery_is_complete_immutable_and_versioned
    templates = StructuredDataset.template_registry.all
    required = %w[
      blood_tests medication_schedules blood_pressure weight heart_rate sleep exercise nutrition
      expenses income subscriptions trades positions equity_curve contacts meetings interactions
      key_value_measurements custom_observation_log
    ]
    assert_empty required - templates.map(&:id)
    assert templates.all?(&:frozen?)
    assert templates.all? { |template| template.version == "1.0.0" }
    blood = StructuredDataset.template_registry.fetch("blood_tests")
    assert_equal %w[test_date panel analyte value unit reference_low reference_high reference_text flag specimen laboratory comments observed_at marker notes],
                 blood.definition.columns.map(&:name)
    assert_includes blood.adapters, "pdf"
    assert_includes blood.recommended_analyzers, "reference_range"
    assert_equal "private", blood.privacy_level
  end

  def test_smart_selection_handles_pdf_csv_excel_and_ocr_renditions
    cases = {
      "pdf-text" => [LAB_REPORT, "blood_tests"],
      "ocr-text" => [LAB_REPORT.gsub("CLINICAL", "OCR"), "blood_tests"],
      "csv" => ["date,category,amount,currency,merchant\n2026-07-30,Travel,42,EUR,Synthetic Rail\n", "expenses"],
      "excel" => ["timestamp\tticker\tside\tqty\tprice\tcurrency\n2026-07-30T10:00:00Z\tSYN\tbuy\t2\t10\tUSD\n", "trades"]
    }
    cases.each do |source_type, (content, expected)|
      observation = StructuredDataset::TemplateObservation.new(
        source_type: source_type, content: content, captured_at: FIXED_TIME
      )
      selection = StructuredDataset.template_registry.select(observation)
      refute_nil selection, source_type
      assert_equal expected, selection.template.id, source_type
      assert_operator selection.confidence, :>=, 0.60, source_type
      refute_empty selection.template.parse(observation), source_type
    end
  end

  def test_blood_pdf_provisions_imports_retries_and_preserves_evidence
    with_schema_vault do |root|
      store = KnowledgeExtraction::ProposalStore.new(vault_root: root, clock: -> { FIXED_TIME })
      builder = StructuredDataset::DatasetProposalBuilder.new(
        vault_root: root, proposal_store: store,
        classifier: KnowledgeGraph::ChatIntentResolver.classifier,
        clock: -> { FIXED_TIME }
      )
      result = builder.create(
        "source_type" => "pdf-text", "content" => LAB_REPORT,
        "captured_at" => FIXED_TIME.iso8601, "title" => "synthetic-blood-report.pdf",
        "source_uri" => "object://synthetic/synthetic-blood-report.pdf",
        "origin_source" => "hermes"
      )
      assert_equal "blood_tests", result.dig("template_selection", "template")
      assert_equal 0.98, result.dig("template_selection", "confidence")
      assert_equal 2, result.fetch("parsed_entry_count")
      assert_equal "create", result.dig("planned_dataset", "action")
      assert_includes result.fetch("confirmation"), "A new Blood Tests collection will be created."
      refute_includes result.fetch("confirmation"), "schema"
      refute_includes result.fetch("confirmation"), "SQL"

      proposal = store.load(result.fetch("proposal_id"))
      assert_equal %w[CreateDataset InsertDatasetRow InsertDatasetRow],
                   proposal.fetch("planned_intents").map { |item| item.dig("intent", "type") }
      prerequisite = proposal.fetch("planned_intents").first
      proposal.fetch("planned_intents")[1..-1].each do |planned|
        assert_equal [prerequisite.fetch("planned_intent_id")], planned.fetch("dependencies")
        assert planned.dig("intent", "params", "evidence_id")
        assert planned.dig("intent", "params", "source_page")
      end

      store.approve(
        proposal_id: result.fetch("proposal_id"),
        intent_ids: proposal.fetch("planned_intents").map { |item| item.fetch("planned_intent_id") },
        actor_id: "template-test"
      )
      datasets = dataset_engine(root)
      graph_engine = KnowledgeGraph::Engine.new(
        vault_root: root, run_id: RUN_ID, actor_id: "template-test", clock: -> { FIXED_TIME }
      )
      submitter = KnowledgeExtraction::ProposalSubmitter.new(
        engine: graph_engine, store: store, dataset_engine: datasets, clock: -> { FIXED_TIME }
      )
      submission = submitter.submit(result.fetch("proposal_id"))
      assert_equal "executed", submission.fetch("status"), submission.inspect

      retry_submission = submitter.submit(result.fetch("proposal_id"))
      assert_equal "executed", retry_submission.fetch("status"), retry_submission.inspect
      assert retry_submission.fetch("results").all? { |item| item.fetch("replayed") }

      description = datasets.describe("blood_tests")
      assert_equal "blood_tests", description.fetch("template")
      assert_equal "1.0.0", description.fetch("template_version")
      rows = datasets.query("blood_tests", order: "analyte:asc")
      assert_equal %w[Ferritin LDL\ Cholesterol], rows.map { |row| row.fetch("analyte") }
      flagged = rows.find { |row| row["analyte"] == "LDL Cholesterol" }
      assert_equal "H", flagged.fetch("flag")
      assert_equal "synthetic-blood-report.pdf", flagged.fetch("source_filename")
      assert_equal "object://synthetic/synthetic-blood-report.pdf", flagged.fetch("source_uri")
      assert_equal 1, flagged.fetch("source_page")
      assert_match(/\A\d+:\d+\z/, flagged.fetch("source_span"))
      assert_match(/\Aevidence_/, flagged.fetch("evidence_id"))

      source_id = proposal.dig("source", "source_id")
      evidence = KnowledgeExtraction::SourceEvidenceStore.new(vault_root: root).load(source_id)
      assert_equal LAB_REPORT.strip, evidence.fetch("content").strip
      assert_equal "object://synthetic/synthetic-blood-report.pdf", evidence.fetch("source_uri")
      source_registry = JSON.parse(
        File.read(File.join(root, KnowledgeExtraction::ProposalStore::RUNTIME, "sources.json"))
      )
      assert_match(%r{\A\.knowledge/evidence/sources/}, source_registry.first.fetch("evidence_path"))
      graph_note = File.read(File.join(root, description.fetch("graph_path")))
      assert_includes graph_note, "dataset_template: \"blood_tests\""
      refute_includes graph_note, "LDL Cholesterol"
    end
  end

  def test_chat_explain_reports_template_plan_without_schema_details
    with_schema_vault do |root|
      status, output, errors = run_cli(
        root, "chat", "--text", LAB_REPORT, "--source-type", "pdf-text",
        "--timestamp", FIXED_TIME.iso8601, "--json", "--explain"
      )
      assert_equal 0, status, errors
      payload = JSON.parse(output)
      assert_equal "dataset", payload.fetch("route")
      assert_equal "blood_tests", payload.dig("explain", "template")
      assert_equal 0.98, payload.dig("explain", "confidence")
      assert_equal "recognized a clinical laboratory report", payload.dig("explain", "reason")
      assert_equal "Blood Tests", payload.dig("explain", "planned_dataset")
      assert_equal 2, payload.dig("explain", "planned_import_count")
      refute_includes JSON.generate(payload.fetch("explain")).downcase, "sqlite"
      refute_includes JSON.generate(payload.fetch("explain")).downcase, "schema_json"
    end
  end

  def test_template_semantics_drive_analysis_and_review_only_recommendation
    with_schema_vault do |root|
      datasets = dataset_engine(root)
      template = StructuredDataset.template_registry.fetch("blood_tests")
      datasets.create(
        "blood_tests", schema: template.definition, template_id: template.id,
        template_version: template.version, template_digest: template.digest
      )
      datasets.insert("blood_tests", {
        test_date: "2026-07-30", panel: "Synthetic", analyte: "Synthetic Marker",
        value: 12, unit: "u/L", reference_low: 2, reference_high: 10,
        observed_at: "2026-07-30T00:00:00Z", marker: "Synthetic Marker"
      }, source: "synthetic")
      response = KnowledgeAnalysis::Engine.new(
        vault_root: root, dataset_engine: datasets, clock: -> { FIXED_TIME }
      ).analyze(
        "How many biomarkers are outside the reference range?",
        propose_recommendations: true
      )
      analysis = response.fetch("analysis")
      assert_includes analysis.fetch("summary"), "1 laboratory measurement is outside"
      assert_equal "template-semantics", analysis.dig("analysis_modules", 0, "name")
      recommendation = analysis.fetch("recommendations").first
      assert_equal "proposal_only", recommendation.fetch("status")
      assert_equal false, recommendation.fetch("executed")
      assert recommendation.fetch("proposal_id")
    end
  end

  def test_existing_blood_dataset_receives_an_additive_template_upgrade
    with_schema_vault do |root|
      datasets = dataset_engine(root)
      legacy = StructuredDataset::Definition.from_h(
        slug: "blood_tests", name: "Blood Tests", kind: "blood_tests",
        purpose: "Longitudinal laboratory results", sensitivity: "private",
        columns: [
          { name: "observed_at", type: "DATETIME", required: true, index: true },
          { name: "marker", type: "TEXT", required: true, index: true },
          { name: "value", type: "REAL", required: true },
          { name: "unit", type: "TEXT", required: true }
        ]
      )
      datasets.create("blood_tests", schema: legacy)
      datasets.insert("blood_tests", {
        observed_at: "2026-07-01T00:00:00Z", marker: "Legacy Marker",
        value: 4, unit: "u/L"
      })
      template = StructuredDataset.template_registry.fetch("blood_tests")
      plan = StructuredDataset::AutonomousRegistry.new(
        vault_root: root, engine: datasets, clock: -> { FIXED_TIME }
      ).plan(
        dataset: "blood_tests",
        values: template.parse(
          StructuredDataset::TemplateObservation.new(
            source_type: "pdf-text", content: LAB_REPORT, captured_at: FIXED_TIME
          )
        ).first.values,
        schema: template.definition, template: template
      )
      assert_equal "schema_upgrade", plan.kind
      assert_includes plan.added_columns, "test_date"
      assert_includes plan.added_columns, "analyte"
      refute plan.definition.column("test_date").required?
      assert_equal "DATE", plan.definition.column("test_date").type

      datasets.migrate("blood_tests", plan.definition)
      assert_equal "Legacy Marker", datasets.query("blood_tests").first.fetch("marker")
    end
  end

  def test_trusted_plugin_can_register_a_future_template_without_engine_changes
    definition = StructuredDataset::Definition.from_h(
      slug: "mood_scores", name: "Mood Scores", kind: "mood_scores",
      purpose: "Synthetic mood observations", sensitivity: "private",
      columns: [
        { name: "observed_at", type: "DATETIME", required: true, index: true },
        { name: "score", type: "INTEGER", required: true, min: 1, max: 5 }
      ]
    )
    template = StructuredDataset::DatasetTemplate.new(
      id: "mood_scores", version: "1.0.0", domain: "health", definition: definition,
      parser: StructuredDataset::TemplateParsers::Delimited.new, plugin: "synthetic-plugin",
      keywords: ["mood"], header_aliases: { "date" => "observed_at", "mood" => "score" },
      recommended_analyzers: ["mood_trend"], visualizations: ["line_chart"],
      adapters: ["future-device"], validation_rules: ["bounded_score"],
      recommendation_rules: ["review_only"],
      analysis_semantics: { "time_column" => "observed_at", "value_columns" => ["score"] }
    )
    plugin = Struct.new(:name, :dataset_templates).new("synthetic-plugin", [template])
    registry = StructuredDataset::TemplateRegistry.new
    registry.register_plugin(plugin)
    assert_equal ["mood_scores"], registry.discover.map { |item| item.fetch("id") }
    selection = registry.select(
      StructuredDataset::TemplateObservation.new(
        source_type: "csv", content: "date,mood\n2026-08-01T10:00:00Z,4\n"
      )
    )
    assert_equal "mood_scores", selection.template.id
    assert_equal 4, selection.template.parse(
      StructuredDataset::TemplateObservation.new(
        source_type: "csv", content: "date,mood\n2026-08-01T10:00:00Z,4\n"
      )
    ).first.values.fetch("score")
  end
end
