# frozen_string_literal: true

require_relative "test_support"

class StructuredDatasetStorageTest < Minitest::Test
  def test_golden_builtin_datasets_are_extensible_typed_definitions
    golden = JSON.parse(File.read(File.expand_path("golden/datasets.json", __dir__)))
    assert_operator StructuredDataset::Builtins.keys.length, :>=, 13
    golden.each do |item|
      definition = StructuredDataset::Builtins.fetch(item.fetch("slug"))
      refute_nil definition
      assert_equal item.fetch("columns"), definition.columns.map(&:name)
      assert definition.columns.all? { |column| StructuredDataset::Column::TYPES.include?(column.type) }
    end
  end

  def test_create_registers_semantics_in_graph_and_schema_in_one_sqlite_database
    with_schema_vault do |root|
      engine = dataset_engine(root)
      created = engine.create("blood_tests", owner_id: nil)

      assert_equal "sqlite", created.fetch("storage")
      assert_equal "blood_tests", created.fetch("table")
      assert_equal 1, created.fetch("schema_version")
      graph_note = File.read(File.join(root, created.fetch("graph_path")))
      assert_includes graph_note, "dataset_slug: \"blood_tests\""
      assert_includes graph_note, "purpose: \"Longitudinal laboratory results\""
      refute_includes graph_note, "schema_json"
      assert File.file?(engine.database.path)

      engine.database.with_connection do |database|
        assert_equal 1, database.get_first_value("PRAGMA foreign_keys")
        assert_equal 3, database.get_first_value("PRAGMA user_version")
        assert_equal %w[blood_tests sde_activity sde_datasets sde_schema_versions],
                     database.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").map { |row| row["name"] }
      end
    end
  end

  def test_insert_update_safe_query_delete_and_privacy
    with_schema_vault do |root|
      engine = dataset_engine(root)
      description = engine.create("blood_tests")
      row = engine.insert(
        "blood_tests",
        { observed_at: "2026-08-01T10:00:00Z", marker: "Hemoglobin", value: 14.2, unit: "g/dL" },
        source: "synthetic-lab", observation_id: "observation_synthetic",
        proposal_id: "proposal_synthetic", approval_id: "approval_synthetic"
      )

      assert_match(/\Arow_[0-9A-HJKMNP-TV-Z]{26}\z/, row.fetch("row_id"))
      assert_equal "synthetic-lab", row.fetch("source")
      assert_equal "proposal_synthetic", row.fetch("proposal_id")
      assert_raises(StructuredDataset::InvalidQuery) do
        engine.query("blood_tests", where: "marker='Hemoglobin' OR 1=1")
      end

      updated = engine.update("blood_tests", row.fetch("row_id"), { value: 14.5 }, source: "correction")
      assert_equal 14.5, updated.fetch("value")
      assert_equal 1, engine.stats("blood_tests").fetch("row_count")
      graph_note = File.read(File.join(root, description.fetch("graph_path")))
      refute_includes graph_note, "14.2"
      refute_includes graph_note, "14.5"

      deleted = engine.delete("blood_tests", row.fetch("row_id"), source: "correction")
      assert deleted.fetch("deleted")
      assert_empty engine.query("blood_tests")
    end
  end

  def test_all_supported_types_and_constraints_are_coerced
    with_schema_vault do |root|
      schema = {
        name: "Types", kind: "custom", purpose: "Exercise every supported type", sensitivity: "normal",
        columns: [
          { name: "text_value", type: "TEXT", required: true, pattern: "[a-z]+" },
          { name: "integer_value", type: "INTEGER", min: 1 },
          { name: "real_value", type: "REAL", max: 10 },
          { name: "boolean_value", type: "BOOLEAN" },
          { name: "date_value", type: "DATE" },
          { name: "datetime_value", type: "DATETIME" },
          { name: "json_value", type: "JSON" }
        ]
      }
      engine = dataset_engine(root)
      engine.create("types", schema: schema)
      row = engine.insert(
        "types",
        {
          text_value: "valid", integer_value: "2", real_value: "3.5", boolean_value: "yes",
          date_value: "2026-08-01", datetime_value: "2026-08-01T10:00:00Z", json_value: { "a" => 1 }
        }
      )
      assert_equal true, row.fetch("boolean_value")
      assert_equal({ "a" => 1 }, row.fetch("json_value"))
      assert_raises(StructuredDataset::InvalidRow) { engine.insert("types", { text_value: "INVALID" }) }
    end
  end

  def test_schema_migrations_are_versioned_and_additive_only
    with_schema_vault do |root|
      engine = dataset_engine(root)
      original = engine.create("weight")
      schema = {
        slug: "weight", name: "Weight", kind: "weight", purpose: "Track body weight", sensitivity: "private",
        columns: original.fetch("columns") + [{ name: "device", type: "TEXT" }]
      }
      migrated = engine.migrate("weight", schema)
      assert_equal 2, migrated.fetch("schema_version")
      assert_equal [1, 2], migrated.fetch("schema_history").map { |item| item.fetch("version") }

      destructive = schema.merge(columns: schema.fetch(:columns).drop(1))
      assert_raises(StructuredDataset::MigrationError) { engine.migrate("weight", destructive) }
    end
  end
end
