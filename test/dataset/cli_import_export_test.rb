# frozen_string_literal: true

require "tempfile"
require_relative "test_support"

class StructuredDatasetCLIImportExportTest < Minitest::Test
  def test_every_requested_cli_command_has_json_output
    with_schema_vault do |root|
      status, output, errors = run_cli(root, "dataset", "create", "weight", "--json")
      assert_equal 0, status, errors
      assert_equal "ok", JSON.parse(output).fetch("status")

      status, output, errors = run_cli(
        root, "dataset", "insert", "weight", "observed_at=2026-08-01T10:00:00Z", "weight_kg=80.5",
        "--source", "scale", "--json"
      )
      assert_equal 0, status, errors
      row_id = JSON.parse(output).dig("result", "row_id")

      %w[list describe stats].each do |command|
        arguments = ["dataset", command]
        arguments << "weight" unless command == "list"
        status, payload, errors = run_cli(root, *arguments, "--json")
        assert_equal 0, status, "#{command}: #{errors}"
        assert_equal "ok", JSON.parse(payload).fetch("status")
      end

      status, payload, errors = run_cli(root, "dataset", "query", "weight", "--where", "weight_kg>=80", "--json")
      assert_equal 0, status, errors
      assert_equal row_id, JSON.parse(payload).dig("result", "rows", 0, "row_id")

      status, payload, errors = run_cli(root, "dataset", "explain", "weight", row_id, "--json")
      assert_equal 0, status, errors
      assert JSON.parse(payload).dig("result", "query_plan").any?

      status, payload, errors = run_cli(root, "dataset", "update", "weight", row_id, "weight_kg=80", "--json")
      assert_equal 0, status, errors
      assert_equal 80.0, JSON.parse(payload).dig("result", "weight_kg")

      status, payload, errors = run_cli(root, "dataset", "delete", "weight", row_id, "--json")
      assert_equal 0, status, errors
      assert JSON.parse(payload).dig("result", "deleted")
    end
  end

  def test_csv_json_and_xlsx_import_export_round_trip
    with_schema_vault do |root|
      engine = dataset_engine(root)
      engine.create("exercise")
      engine.insert(
        "exercise",
        { started_at: "2026-08-01T08:00:00Z", activity: "Running", duration_minutes: 30, distance_km: 5.2 },
        source: "synthetic-watch"
      )
      transfer = StructuredDataset::ImportExport.new(engine: engine)

      Dir.mktmpdir("sde-transfer-") do |directory|
        %w[csv json xlsx].each do |format|
          path = File.join(directory, "exercise.#{format}")
          exported = transfer.export("exercise", format: format, path: path)
          assert_equal 1, exported.fetch("row_count")
          assert File.file?(path)

          target = "exercise_#{format}"
          schema = StructuredDataset::Builtins.fetch("exercise").to_h.merge(slug: target, name: "Exercise #{format.upcase}")
          engine.create(target, schema: schema)
          imported = transfer.import(target, path: path, format: format, provenance: { source: "round-trip" })
          assert_equal 1, imported.fetch("inserted")
          assert_equal "Running", engine.query(target).first.fetch("activity")
        end
      end
    end
  end
end
