# frozen_string_literal: true
require_relative "test_support"
require_relative "../dataset/test_support"
require_relative "health_fixture"

class HealthReadsTest < Minitest::Test
  include HealthReadFixture
  GRANTS = %w[graph:read dataset:read health:read].freeze

  def typed(root, operation, arguments = {}, grants: GRANTS, reader: nil)
    options = reader ? { read_only_services: true, dataset_engine_factory: -> { reader } } : {}
    gateway = AgentPlatform.build(vault_root: root, environment: "read_only", clock: -> { Time.utc(2026, 10, 25) }, **options)
    agent = AgentPlatform::AgentIdentity.new(id: "lab-reader", permissions: grants)
    invoke(gateway, agent, "kg.health.#{operation}", arguments)
  end

  def payload(root, op = "labs", args = { "subject_id" => SUBJECT }, **options)
    response = typed(root, op, args, **options)
    assert response.success?, response.to_h.inspect
    response.payload
  end

  def test_original_rows_scopes_qualitative_values_and_separate_series_without_writers
    with_schema_vault do |root|
      HealthReadFixture.build(root)
      before = HealthReadFixture.logical(root)
      notes = Dir.glob(File.join(root, "**/*.md")).to_h { |path| [path, File.binread(path)] }
      refuse = ->(**_options) { flunk "laboratory read constructed a writer" }
      StructuredDataset::Engine.stub(:new, refuse) do
        KnowledgeGraph::Engine.stub(:new, refuse) do
          KnowledgeExtraction::ProposalStore.stub(:new, refuse) do
            scopes = payload(root, "labs", "scopes" => true)
            assert_equal [SUBJECT, OTHER], scopes.dig("data", "subjects").map { |item| item["id"] }
            rows = payload(root).dig("data", "items")
            assert_equal 9, rows.length
            assert_equal ["123", "<5", "Negative"], rows.map { |row| row["value"] }.grep(String).sort
            assert_equal 12.0, rows.find { |row| row["test_date"] == "2026-10-25" && row["value"].is_a?(Numeric) }["value"]
            assert rows.all? { |row| row["subject_id"] == SUBJECT }
            assert_equal [EVIDENCE], payload(root)["evidence"].map { |item| item["evidence_id"] }
            %w[source_uri source_filename source_span comments approval_id intent_id].each { |key| refute_includes JSON.generate(rows), key }
            series = payload(root, "lab_series", "subject_id" => SUBJECT, "analyte" => ANALYTE)
            assert_equal 6, series.dig("data", "series").length
            assert_equal 9, series.dig("data", "series").sum { |group| group["points"].length }
            group = series.dig("data", "series").find { |item| item["unit"] == "mg/dL" && item["specimen"] == "serum" && !item["method"] && item["laboratory"] == "Synthetic laboratory" }
            assert_equal [14.0, 12.0], group["points"].map { |row| row["value"] }
            assert_equal [11.0, 10.0], group["points"].map { |row| row["reference_high"] }
            assert_equal "none", group["aggregation"]
          end
        end
      end
      assert_equal before, HealthReadFixture.logical(root)
      assert_equal notes, Dir.glob(File.join(root, "**/*.md")).to_h { |path| [path, File.binread(path)] }
    end
  end

  def test_filters_dates_paging_and_uniform_hidden_subject_denials
    with_schema_vault do |root|
      HealthReadFixture.build(root)
      first = payload(root, "labs", "subject_id" => SUBJECT, "limit" => 2)
      second = payload(root, "labs", "subject_id" => SUBJECT, "limit" => 2, "after" => first.dig("data", "page", "after"))
      assert_empty first.dig("data", "items").map { |r| r["row_id"] } & second.dig("data", "items").map { |r| r["row_id"] }
      assert_equal first["source_version"], second["source_version"]
      rows = payload(root, "labs", "subject_id" => SUBJECT, "from" => "2026-10-25", "to" => "2026-10-25", "panel" => "Synthetic panel").dig("data", "items")
      assert_equal [12.0], rows.map { |r| r["value"] }
      assert_equal [777.0], payload(root, "labs", "subject_id" => OTHER).dig("data", "items").map { |r| r["value"] }
      bad = [{}, { "scopes" => true, "subject_id" => SUBJECT }, { "subject_id" => SUBJECT, "from" => "2026-01-01" },
        { "subject_id" => SUBJECT, "from" => "2020-01-01", "to" => "2026-01-01" }, { "subject_id" => SUBJECT, "from" => "2026-02-31", "to" => "2026-03-01" },
        { "subject_id" => SUBJECT, "from" => "2026-01-01T00:00:00Z", "to" => "2026-01-02" }, { "subject_id" => SUBJECT, "after" => ["x"] }]
      bad.each { |args| assert_equal "InvalidArguments", typed(root, "labs", args).errors.first["code"] }
      assert_equal typed(root, "labs", "subject_id" => HIDDEN).errors, typed(root, "labs", "subject_id" => "person_00000000000000000000000099").errors
      %w[health:read graph:read dataset:read].each do |grant|
        gateway = AgentPlatform.build(vault_root: root)
        agent = AgentPlatform::AgentIdentity.new(id: "denied", permissions: GRANTS - [grant])
        refute gateway.discover(agent: agent).any? { |m| m["capability_id"].start_with?("kg.health.") }
      end
    end
  end

  def test_restricted_conjunction_and_hidden_only_source_stability
    with_schema_vault do |root|
      writer = HealthReadFixture.build(root)
      plain = payload(root)
      %w[graph:restricted dataset:restricted].each do |grant|
        assert_equal plain, payload(root, "labs", { "subject_id" => SUBJECT }, grants: GRANTS + [grant])
      end
      assert_equal 10, payload(root, "labs", { "subject_id" => SUBJECT }, grants: GRANTS + %w[graph:restricted dataset:restricted]).dig("data", "items").length
      hidden = writer.query("clinical_samples").find { |row| row["subject_id"] == HIDDEN }
      writer.update("clinical_samples", hidden["row_id"], { value: 8888 })
      assert_equal plain, payload(root)
      assert_equal [8888.0], payload(root, "labs", { "subject_id" => HIDDEN }, grants: GRANTS + %w[graph:restricted dataset:restricted]).dig("data", "items").map { |r| r["value"] }
      # Dataset sensitivity also requires both exceptional grants.
      record = KnowledgeGraph::Repository.new(vault_root: root, registry: KnowledgeGraph::SchemaRegistry.new(vault_root: root)).resolve(writer.describe("clinical_samples")["dataset_id"])
      File.write(File.join(root, record.relative_path), YAML.dump(record.data.merge("sensitivity" => "restricted")) + "---\n" + record.body)
      assert_equal 3, payload(root).dig("data", "items").length
      assert_equal 3, payload(root, "labs", { "subject_id" => SUBJECT }, grants: GRANTS + ["graph:restricted"]).dig("data", "items").length
    end
  end

  def test_legacy_unknown_subject_unsupported_and_storage_states_are_nonmigrating
    with_schema_vault do |root|
      create_base_entities(root)
      writer = dataset_engine(root)
      writer.create("blood_tests", schema: { columns: [{name: "observed_at", type: "DATETIME"}, {name: "marker", type: "TEXT"}, {name: "value", type: "TEXT"}] })
      writer.insert("blood_tests", { observed_at: "2026-10-25T23:30:00-05:00", marker: "Novel", value: "Negative" })
      assert_includes payload(root, "labs", "scopes" => true)["limitations"], "subject_scope_unknown"
      assert_includes payload(root, "labs", "subject_id" => PERSON_ID)["limitations"], "subject_scope_unknown"
      record = KnowledgeGraph::Repository.new(vault_root: root, registry: KnowledgeGraph::SchemaRegistry.new(vault_root: root)).resolve(writer.describe("blood_tests")["dataset_id"])
      file = File.join(root, record.relative_path)
      File.write(file, YAML.dump(record.data.merge("owner_id" => PERSON_ID)) + "---\n" + record.body)
      row = payload(root, "labs", "subject_id" => PERSON_ID).dig("data", "items", 0)
      assert_equal "2026-10-25", row["test_date"]
      assert_equal "Novel", row["analyte"]
      assert_equal "Negative", row["value"]
      File.write(file, YAML.dump(record.data.merge("owner_id" => PERSON_ID, "dataset_template" => "blood_tests", "dataset_template_version" => "9.0.0")) + "---\n" + record.body)
      assert_includes payload(root, "labs", "subject_id" => PERSON_ID)["limitations"], "laboratory_schema_unsupported"
    end
    with_schema_vault do |root|
      HealthReadFixture.build(root)
      path = File.join(root, KnowledgeSDK::DATASET_PATH)
      [1, 4].each do |version|
        db = SQLite3::Database.new(path); db.execute("PRAGMA user_version = #{version}"); db.close
        bytes = File.binread(path)
        assert_equal "unavailable", payload(root)["status"]
        assert_equal bytes, File.binread(path)
      end
      FileUtils.rm_f(path)
      assert_includes payload(root)["limitations"], "dataset_storage_missing"
      refute File.exist?(path)
    end
    with_schema_vault do |root|
      paths = Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH)
      assert_equal "unavailable", payload(root, "labs", "scopes" => true)["status"]
      assert_equal paths, Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH)
    end
  end

  def test_scope_conflicts_empty_owners_unknown_columns_references_and_group_bounds
    with_schema_vault do |root|
      HealthReadFixture.build(root)
      create_base_entities(root)
      assert_equal "PolicyDenied", typed(root, "labs", "subject_id" => PERSON_ID).errors.first["code"]
      reader = StructuredDataset::Reader.new(vault_root: root, database_path: File.join(root, KnowledgeSDK::DATASET_PATH))
      numeric_id = reader.describe("clinical_samples")["dataset_id"]
      row = reader.query("clinical_samples").find { |item| item["value"] == 12 }
      reader.stub(:query, ->(*_args, **_options) { [] }) do
        scopes = payload(root, "labs", { "scopes" => true }, reader: reader)
        assert_equal [SUBJECT], scopes.dig("data", "subjects").map { |item| item["id"] }
        assert_equal "empty", payload(root, "labs", { "subject_id" => SUBJECT }, reader: reader)["status"]
      end
      reader.stub(:query, ->(id, **_options) { id == numeric_id ? (0..10).map { |i| row.merge("method" => "Recorded method #{i}") } : [] }) do
        result = payload(root, "lab_series", { "subject_id" => SUBJECT, "analyte" => ANALYTE }, reader: reader)
        assert_equal "partial", result["status"]
        assert_equal 10, result.dig("data", "series").length
        assert_includes result["limitations"], "series_bound_reached"
      end
      reader.stub(:query, ->(*_args, **_options) { [row.merge("subject_id" => OTHER)] }) do
        assert_includes payload(root, "labs", { "subject_id" => SUBJECT }, reader: reader)["limitations"], "subject_scope_conflict"
      end
      reader.stub(:query, ->(*_args, **_options) { [row.merge("panel" => "Linked to #{HIDDEN}")] }) do
        assert_equal "empty", payload(root, "labs", { "subject_id" => SUBJECT }, reader: reader)["status"]
      end
      describe = reader.method(:describe)
      reader.stub(:describe, ->(id) { describe.call(id).merge("columns" => [{ name: "unknown_custom_field", type: "TEXT" }]) }) do
        assert_includes payload(root, "labs", { "subject_id" => SUBJECT }, reader: reader)["limitations"], "laboratory_schema_unsupported"
      end
    end
  end

  def test_raw_series_bounds_and_source_scan_refusal
    with_schema_vault do |root|
      HealthReadFixture.build(root)
      reader = StructuredDataset::Reader.new(vault_root: root, database_path: File.join(root, KnowledgeSDK::DATASET_PATH))
      row = reader.query("clinical_samples").find { |r| r["value"] == 12 }
      reader.stub(:query, ->(id, **_options) { id == reader.describe("clinical_samples")["dataset_id"] ? Array.new(1001) { |i| row.merge("row_id" => "row_#{format('%026d', i)}") } : [] }) do
        result = payload(root, "lab_series", { "subject_id" => SUBJECT, "analyte" => ANALYTE }, reader: reader)
        assert_equal "partial", result["status"]
        assert_equal 1000, result.dig("data", "series", 0, "points").length
        assert_equal true, result.dig("data", "series", 0, "bounded")
        assert_includes result["limitations"], "series_point_bound_reached"
      end
      calls = 0
      reader.stub(:query, ->(*_args, **_options) { calls += 1; Array.new(10_000, row) }) do
        result = payload(root, "lab_series", { "subject_id" => SUBJECT, "analyte" => ANALYTE }, reader: reader)
        assert_equal "unavailable", result["status"]
        assert_includes result["limitations"], "laboratory_source_bound_reached"
        assert_nil result["data"]
      end
      assert_equal 11, calls
    end
  end
end
