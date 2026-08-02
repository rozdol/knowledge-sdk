# frozen_string_literal: true

require_relative "test_support"

class StructuredDatasetEvolutionTest < Minitest::Test
  class InsertMedicationDetail < KnowledgeGraph::DatasetIntent
    field :observed_at
    field :name
    field :dose
    field :before_meal
    field :doctor
    field :reason
  end

  def test_missing_dataset_is_created_and_original_observation_runs_after_one_approval
    with_schema_vault do |root|
      status, output, errors = run_cli(
        root, "chat", "--text", "My weight is 82.3 kg",
        "--timestamp", "2026-08-02T09:30:00Z", "--json", "--explain"
      )
      assert_equal 0, status, errors
      proposal_id = JSON.parse(output).dig("result", "proposal_id")
      proposal = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(proposal_id)
      assert_equal %w[CreateDataset InsertWeightMeasurement],
                   proposal.fetch("planned_intents").map { |item| item.dig("intent", "type") }
      create = proposal.fetch("planned_intents").first
      insert = proposal.fetch("planned_intents").last
      assert_equal [create.fetch("planned_intent_id")], insert.fetch("dependencies")
      assert_empty create.fetch("blocked_reasons")

      status, _approval, errors = run_cli(
        root, "proposal", "approve", proposal_id, "--all", "--actor", "evolution-test"
      )
      assert_equal 0, status, errors
      status, submission, errors = run_cli(root, "proposal", "submit", proposal_id)
      assert_equal 0, status, errors
      payload = JSON.parse(submission)
      assert_equal "executed", payload.fetch("status")
      assert_equal %w[CreateDataset InsertWeightMeasurement],
                   payload.fetch("results").map { |item| item.fetch("intent_type") }
      assert_equal 82.3, dataset_engine(root).query("weight").first.fetch("weight_kg")
      activities = KnowledgeActivity::Timeline.new(vault_root: root).recent(limit: 10)
      assert activities.any? { |item| item.summary.include?("was registered") }
      assert activities.any? { |item| item.summary.include?("received a row") }
    end
  end

  def test_schema_mismatch_generates_upgrade_dependency_then_retries_row
    with_schema_vault do |root|
      datasets = dataset_engine(root)
      datasets.create("medication_details", schema: {
        slug: "medication_details", name: "Medication Details", kind: "medication_details",
        purpose: "Synthetic medication observations", sensitivity: "private",
        columns: [
          { name: "observed_at", type: "DATETIME", required: true, index: true },
          { name: "name", type: "TEXT", required: true },
          { name: "dose", type: "REAL" }
        ]
      })
      register_medication_route
      classifier = KnowledgeSDK::IntentClassifier.new
      classifier.register(name: "medication-detail-test", route: "dataset") do |_text, _context|
        {
          "intent" => "dataset.medication_detail", "confidence" => 0.99,
          "reason" => "synthetic schema evolution observation",
          "slots" => {
            "observed_at" => "2026-08-02T09:30:00Z", "name" => "Syntheticine",
            "dose" => 10.0, "before_meal" => true, "doctor" => "Dr Example",
            "reason" => "Synthetic fixture"
          }
        }
      end
      store = KnowledgeExtraction::ProposalStore.new(vault_root: root, clock: -> { FIXED_TIME })
      result = StructuredDataset::DatasetProposalBuilder.new(
        vault_root: root, proposal_store: store, classifier: classifier, clock: -> { FIXED_TIME }
      ).create(
        "source_type" => "chat", "content" => "Synthetic medication detail",
        "captured_at" => "2026-08-02T09:30:00Z", "origin_source" => "test"
      )
      proposal = store.load(result.fetch("proposal_id"))
      assert_equal "DatasetSchemaUpgradeProposal", result.dig("dataset_evolution", "proposal_type")
      assert_equal %w[UpgradeDatasetSchema InsertMedicationDetail],
                   proposal.fetch("planned_intents").map { |item| item.dig("intent", "type") }
      upgrade = proposal.fetch("planned_intents").first
      row = proposal.fetch("planned_intents").last
      assert_equal %w[before_meal doctor reason], upgrade.dig("intent", "params", "added_columns")
      assert_equal [upgrade.fetch("planned_intent_id")], row.fetch("dependencies")

      approval = store.approve(
        proposal_id: result.fetch("proposal_id"),
        intent_ids: proposal.fetch("planned_intents").map { |item| item.fetch("planned_intent_id") },
        actor_id: "evolution-test"
      )
      graph_engine = KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME })
      submission = KnowledgeExtraction::ProposalSubmitter.new(
        engine: graph_engine, store: store, dataset_engine: datasets, clock: -> { FIXED_TIME }
      ).submit(result.fetch("proposal_id"))
      assert_equal "executed", submission.fetch("status"), submission.inspect
      assert_equal 2, datasets.describe("medication_details").fetch("schema_version")
      inserted = datasets.query("medication_details").first
      assert_equal true, inserted.fetch("before_meal")
      assert_equal "Dr Example", inserted.fetch("doctor")
      assert_equal approval.fetch("approval_id"), inserted.fetch("approval_id")
      assert datasets.activity_records.any? { |item| item["action"] == "migrate" }
    end
  end

  def test_existing_medication_schedule_gets_optional_details_upgrade
    with_schema_vault do |root|
      datasets = dataset_engine(root)
      datasets.create("medication_schedules", schema: {
        slug: "medication_schedules", name: "Medication Schedules",
        kind: "medication_schedules", purpose: "Synthetic legacy schedules",
        sensitivity: "private", columns: [
          { name: "effective_on", type: "DATE", required: true, index: true },
          { name: "medication", type: "TEXT", required: true, unique: true },
          { name: "dose", type: "REAL" }, { name: "unit", type: "TEXT" },
          { name: "schedule", type: "TEXT", required: true },
          { name: "active", type: "BOOLEAN", required: true }
        ]
      })

      status, output, errors = run_cli(
        root, "chat", "--text", "Я принимаю Berberine утром",
        "--timestamp", "2026-08-02T09:30:00Z", "--json"
      )
      assert_equal 0, status, errors
      proposal_id = JSON.parse(output).dig("result", "proposal_id")
      proposal = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(proposal_id)
      assert_equal %w[UpgradeDatasetSchema CreateMedicationSchedule],
                   proposal.fetch("planned_intents").map { |item| item.dig("intent", "type") }
      migration = proposal.fetch("planned_intents").first
      assert_equal StructuredDataset::MedicationScheduleSchemaMigration::ID,
                   migration.dig("intent", "params", "migration_id")
      assert_includes migration.dig("intent", "params", "added_columns"), "schedule_json"
      assert_includes migration.dig("intent", "params", "added_columns"), "effective_from"
      assert_empty datasets.query("medication_schedules")
    end
  end

  private

  def register_medication_route
    StructuredDataset.routing_registry.register(
      intent: "dataset.medication_detail", dataset: "medication_details",
      intent_class: InsertMedicationDetail,
      builder: ->(common, slots) { InsertMedicationDetail.new(**common.merge(slots)) },
      writer: lambda do |engine, intent, provenance|
        engine.insert(
          "medication_details",
          {
            observed_at: intent.observed_at, name: intent.name, dose: intent.dose,
            before_meal: intent.before_meal, doctor: intent.doctor, reason: intent.reason
          },
          provenance
        )
      end
    )
  end
end
