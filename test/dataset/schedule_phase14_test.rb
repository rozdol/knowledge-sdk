# frozen_string_literal: true

require_relative "test_support"

class StructuredSchedulePhase14Test < Minitest::Test
  def test_generic_schedule_value_supports_recurrence_shapes_and_is_immutable
    daily = KnowledgeSDK::Schedule.from_h(
      frequency: "daily",
      times: [
        { time_of_day: "morning", meal_relation: "before_food", fasting: true },
        { local_time: "18:30" }
      ]
    )
    assert_equal 2, daily.to_h.fetch("times").length
    assert daily.frozen?
    assert_raises(FrozenError) { daily.to_h.fetch("frequency").replace("weekly") }

    weekly = KnowledgeSDK::Schedule.from_h(
      frequency: "weekly", days_of_week: %w[monday friday],
      times: [{ time_of_day: "evening" }]
    )
    assert_equal %w[monday friday], weekly.to_h.fetch("days_of_week")
    assert_equal "every_n_days", KnowledgeSDK::Schedule.from_h(
      frequency: "every_n_days", interval: { every: 3, unit: "days", anchor_date: "2026-08-01" }
    ).frequency
    assert_equal "cron", KnowledgeSDK::Schedule.from_h(
      frequency: "cron", cron: "0 9 * * 1"
    ).frequency
    assert_equal "prn", KnowledgeSDK::Schedule.from_h(frequency: "prn").frequency
    assert_equal "custom_interval", KnowledgeSDK::Schedule.from_h(
      frequency: "custom_interval", interval: { every: 12, unit: "hours" },
      extensions: { "reminder_policy" => "plugin_owned" }
    ).frequency
    schema = JSON.parse(File.read(File.join(
      KnowledgeGraphTestSupport::SDK_ROOT,
      "docs/Structured Dataset Engine/schedule.schema.json"
    )))
    assert AgentPlatform::SchemaValidator.new.validate!(
      schema, daily.to_h, error_class: RuntimeError, label: "schedule"
    )
  end

  def test_multiple_daily_berberine_entries_use_ids_and_structured_schedules
    text = <<~TEXT
      Medication schedule:
      Morning:
      Berberine 500 mg
      Day:
      Berberine 500 mg
      Evening:
      Berberine 500 mg
    TEXT

    with_schema_vault do |root|
      status, output, errors = run_cli(
        root, "chat", "--text", text,
        "--timestamp", "2026-08-02T09:30:00Z", "--json", "--explain"
      )
      assert_equal 0, status, errors
      payload = JSON.parse(output)
      assert_equal 3, payload.dig("result", "parsed_entry_count")
      assert_equal %w[CreateDataset CreateMedicationSchedule CreateMedicationSchedule CreateMedicationSchedule],
                   payload.dig("explain", "generated_intents")
      explained_times = payload.dig("explain", "schedule_object").map do |schedule|
        schedule.dig("times", 0, "time_of_day")
      end
      assert_equal %w[morning day evening], explained_times

      engine = dataset_engine(root)
      refute_includes engine.list.map { |item| item.fetch("slug") }, "medication_schedules"
      approve_and_submit(root, payload.dig("result", "proposal_id"))
      rows = engine.query("medication_schedules", order: "effective_from:asc")
      assert_equal 3, rows.length
      assert_equal 3, rows.map { |row| row.fetch("schedule_id") }.uniq.length
      assert rows.all? { |row| row["medication"] == "Berberine" }
      stored_times = rows.map do |row|
        row.dig("schedule_json", "times", 0, "time_of_day")
      end
      assert_equal %w[day evening morning], stored_times.sort
      medication_column = engine.describe("medication_schedules").fetch("columns").find do |column|
        (column[:name] || column["name"]) == "medication"
      end
      refute medication_column.fetch(:unique, false)
      assert_raises(StructuredDataset::InvalidRow) do
        engine.insert("medication_schedules", {
          schedule_id: "medschedule_01KYYD4HNT4HEWNH1P3DQKTZZZ", medication: "Invalidine",
          schedule_json: { frequency: "hourly" },
          effective_from: "2026-08-02", active: true
        })
      end
    end
  end

  def test_future_temporary_course_pause_resume_and_stop_preserve_intervals
    with_schema_vault do |root|
      create = propose(root, "I take Syntheticine 250 mg every morning starting tomorrow until 2026-08-10")
      approve_and_submit(root, create.fetch("proposal_id"))
      engine = dataset_engine(root)
      initial = engine.query("medication_schedules").first
      assert_equal "2026-08-03", initial.fetch("effective_from")
      assert_equal "2026-08-10", initial.fetch("effective_until")

      pause = propose(root, "Pause medication Syntheticine tomorrow")
      approve_and_submit(root, pause.fetch("proposal_id"))
      paused = engine.query("medication_schedules", order: "effective_from:asc")
      assert_equal 2, paused.length
      assert_equal "2026-08-03", paused.first.fetch("effective_until")
      assert_equal false, paused.last.fetch("active")
      assert_equal "paused", paused.last.fetch("reason")

      resume = propose(
        root, "Resume medication Syntheticine tomorrow", timestamp: "2026-08-04T09:30:00Z"
      )
      approve_and_submit(root, resume.fetch("proposal_id"))
      resumed = engine.query("medication_schedules", order: "effective_from:asc")
      assert_equal 3, resumed.length
      assert_equal "2026-08-05", resumed.last.fetch("effective_from")
      assert_equal true, resumed.last.fetch("active")

      stopped = propose(
        root, "Stop taking Syntheticine tomorrow", timestamp: "2026-08-06T09:30:00Z"
      )
      approve_and_submit(root, stopped.fetch("proposal_id"))
      final = engine.query("medication_schedules", order: "effective_from:asc")
      assert_equal "2026-08-06", final.last.fetch("effective_until")
      assert_equal "discontinued", final.last.fetch("reason")
      assert_equal 3, final.length
    end
  end

  def test_schedule_evolution_closes_current_version_and_appends_future_structure
    with_schema_vault do |root|
      current = propose(root, "I take Berberine 500 mg every morning")
      approve_and_submit(root, current.fetch("proposal_id"))

      future = propose(
        root,
        "I take Berberine 500 mg every morning and every evening starting tomorrow"
      )
      stored = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(future.fetch("proposal_id"))
      intent = stored.fetch("planned_intents").last.dig("intent", "params")
      assert_equal true, intent.fetch("replace_all")
      assert_equal 2, intent.dig("schedule_json", "times").length
      approve_and_submit(root, future.fetch("proposal_id"))

      rows = dataset_engine(root).query("medication_schedules", order: "effective_from:asc")
      assert_equal 2, rows.length
      assert_equal "2026-08-02", rows.first.fetch("effective_until")
      assert_equal "2026-08-03", rows.last.fetch("effective_from")
      future_times = rows.last.dig("schedule_json", "times").map do |time|
        time.fetch("time_of_day")
      end
      assert_equal %w[evening morning], future_times.sort
    end
  end

  def test_legacy_schema_migrates_after_approval_and_preserves_rows
    with_schema_vault do |root|
      engine = dataset_engine(root)
      engine.create("medication_schedules", schema: legacy_schema)
      engine.insert("medication_schedules", {
        effective_on: "2026-08-01", medication: "Berberine", dose: 500,
        unit: "mg", schedule: "every morning", active: true
      })

      proposal = propose(root, "I take Berberine 500 mg every evening")
      stored = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(proposal.fetch("proposal_id"))
      assert_equal %w[UpgradeDatasetSchema CreateMedicationSchedule],
                   stored.fetch("planned_intents").map { |item| item.dig("intent", "type") }
      assert_equal StructuredDataset::MedicationScheduleSchemaMigration::ID,
                   stored.dig("planned_intents", 0, "intent", "params", "migration_id")
      assert_equal 1, engine.describe("medication_schedules").fetch("schema_version")

      approve_and_submit(root, proposal.fetch("proposal_id"))
      assert_equal 2, engine.describe("medication_schedules").fetch("schema_version")
      rows = engine.query("medication_schedules", order: "effective_from:asc")
      assert_equal 2, rows.length
      assert_equal "morning", rows.first.dig("schedule_json", "times", 0, "time_of_day")
      assert_equal "evening", rows.last.dig("schedule_json", "times", 0, "time_of_day")
      assert rows.all? { |row| row.fetch("schedule_id").start_with?("medschedule_") }
      assert engine.activity_records.any? { |event| event["action"] == "migrate" }
    end
  end

  def test_analysis_uses_effective_intervals_and_schedule_objects
    with_schema_vault do |root|
      engine = dataset_engine(root)
      engine.create("medication_schedules")
      engine.insert("medication_schedules", {
        schedule_id: "medschedule_01KYYD4HNT4HEWNH1P3DQKTAAA",
        medication: "Berberine", dose: 500, unit: "mg",
        schedule_json: { frequency: "daily", times: [{ time_of_day: "morning" }] },
        effective_from: "2026-03-01", effective_until: "2026-03-14", active: true
      })
      engine.insert("medication_schedules", {
        schedule_id: "medschedule_01KYYD4HNT4HEWNH1P3DQKTAAC",
        medication: "Berberine", dose: 1000, unit: "mg", reason: "dose_modified",
        schedule_json: { frequency: "daily", times: [{ time_of_day: "morning" }] },
        effective_from: "2026-03-15", effective_until: "2026-03-31", active: true
      })
      engine.insert("medication_schedules", {
        schedule_id: "medschedule_01KYYD4HNT4HEWNH1P3DQKTAAB",
        medication: "Endedine",
        schedule_json: { frequency: "weekly", days_of_week: ["monday"] },
        effective_from: "2026-01-01", effective_until: "2026-02-01", active: true
      })
      engine.create("blood_tests")
      [
        ["2026-03-01T08:00:00Z", 100], ["2026-03-10T08:00:00Z", 110],
        ["2026-03-20T08:00:00Z", 120], ["2026-03-30T08:00:00Z", 130]
      ].each do |observed_at, value|
        engine.insert("blood_tests", {
          observed_at: observed_at, marker: "LDL", value: value, unit: "mg/dL"
        })
      end

      analysis = KnowledgeAnalysis::Engine.new(
        vault_root: root, dataset_engine: engine, clock: -> { FIXED_TIME }
      ).analyze("What medications was I taking in March?", as_of: "2026-08-02").fetch("analysis")
      assert_includes analysis.fetch("summary"), "Berberine"
      assert_equal ["Berberine"], analysis.fetch("possible_factors").map { |item| item.fetch("label") }.uniq
      evidence = analysis.fetch("possible_factors").first.fetch("evidence")
      assert_equal "daily", evidence.dig("schedule", "frequency")
      assert_includes %w[2026-03-01 2026-03-15], evidence.fetch("effective_from")
      refute_includes analysis.fetch("summary"), "Endedine"

      ldl = KnowledgeAnalysis::Engine.new(
        vault_root: root, dataset_engine: engine, clock: -> { FIXED_TIME }
      ).analyze(
        "Which medications were active during my LDL increase?", as_of: "2026-08-02"
      ).fetch("analysis")
      assert ldl.fetch("possible_factors").any? do |factor|
        factor["label"] == "Berberine" && factor.fetch("datasets").include?("medication_schedules")
      end

      changed = KnowledgeAnalysis::Engine.new(
        vault_root: root, dataset_engine: engine, clock: -> { FIXED_TIME }
      ).analyze(
        "Which biomarkers improved after increasing Berberine?", as_of: "2026-08-02"
      ).fetch("analysis")
      assert changed.fetch("possible_factors").any? { |factor| factor["label"].include?("Berberine") }
    end
  end

  def test_explicit_dose_and_schedule_modifications_append_versions
    with_schema_vault do |root|
      created = propose(root, "I take Berberine 500 mg every morning")
      approve_and_submit(root, created.fetch("proposal_id"))

      dose = propose(root, "Change Berberine dose to 1000 mg tomorrow")
      stored = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(dose.fetch("proposal_id"))
      assert_equal "ModifyMedicationDose", stored.dig("planned_intents", 0, "intent", "type")
      approve_and_submit(root, dose.fetch("proposal_id"))

      schedule = propose(
        root, "Change Berberine schedule to every evening tomorrow",
        timestamp: "2026-08-03T09:30:00Z"
      )
      stored = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(schedule.fetch("proposal_id"))
      assert_equal "ModifyMedicationSchedule", stored.dig("planned_intents", 0, "intent", "type")
      approve_and_submit(root, schedule.fetch("proposal_id"))

      rows = dataset_engine(root).query("medication_schedules", order: "effective_from:asc")
      assert_equal 3, rows.length
      assert_equal ["2026-08-02", "2026-08-03"], rows.first(2).map { |row| row.fetch("effective_until") }
      assert_equal 1000.0, rows.last.fetch("dose")
      assert_equal "evening", rows.last.dig("schedule_json", "times", 0, "time_of_day")
    end
  end

  private

  def propose(root, text, timestamp: "2026-08-02T09:30:00Z")
    status, output, errors = run_cli(
      root, "chat", "--text", text, "--timestamp", timestamp, "--json", "--explain"
    )
    assert_equal 0, status, errors
    JSON.parse(output).fetch("result")
  end

  def approve_and_submit(root, proposal_id)
    status, _output, errors = run_cli(
      root, "proposal", "approve", proposal_id, "--all", "--actor", "phase14-test"
    )
    assert_equal 0, status, errors
    status, output, errors = run_cli(root, "proposal", "submit", proposal_id)
    assert_equal 0, status, errors
    assert_equal "executed", JSON.parse(output).fetch("status"), output
  end

  def legacy_schema
    {
      slug: "medication_schedules", name: "Medication Schedules",
      kind: "medication_schedules", purpose: "Synthetic legacy schedules",
      sensitivity: "private", columns: [
        { name: "effective_on", type: "DATE", required: true, index: true },
        { name: "medication", type: "TEXT", required: true, unique: true },
        { name: "dose", type: "REAL" }, { name: "unit", type: "TEXT" },
        { name: "schedule", type: "TEXT", required: true },
        { name: "schedule_details", type: "JSON" },
        { name: "active", type: "BOOLEAN", required: true }
      ]
    }
  end
end
