# frozen_string_literal: true

require_relative "test_support"
require "sqlite3"

class StructuredDatasetReaderTest < Minitest::Test
  def reader(root, path = File.join(root, KnowledgeSDK::DATASET_PATH))
    StructuredDataset::Reader.new(vault_root: root, database_path: path)
  end

  def test_missing_and_old_new_invalid_storage_are_never_provisioned_or_migrated
    with_vault do |root|
      path = File.join(root, "absent", "rows.sqlite3")
      assert_equal "dataset_storage_missing", reader(root, path).availability["code"]
      refute File.exist?(File.dirname(path))
      FileUtils.mkdir_p(File.dirname(path))
      [0, 1, 2, 4, 3].each do |version|
        db = SQLite3::Database.new(path)
        db.execute("PRAGMA user_version = #{version}")
        db.close
        original = File.binread(path)
        expected = version < 3 ? "dataset_upgrade_required" : (version > 3 ? "dataset_engine_too_old" : "dataset_storage_invalid")
        assert_equal expected, reader(root, path).availability["code"]
        assert_equal original, File.binread(path)
      end
      File.binwrite(path, "synthetic invalid sqlite")
      assert_equal "dataset_storage_invalid", reader(root, path).availability["code"]
    end
  end

  def test_current_reader_reuses_query_schema_stats_and_provenance_without_writer_methods
    with_schema_vault do |root|
      writer = dataset_engine(root)
      created = writer.create("weight")
      writer.insert("weight", { observed_at: "2026-10-25T12:00:00Z", weight_kg: 71.5 })
      read = reader(root)
      assert_equal "ready", read.availability["status"]
      assert_equal writer.list, read.list
      assert_equal writer.describe("weight"), read.describe("weight")
      assert_equal writer.query("weight"), read.query("weight")
      assert_equal writer.stats("weight"), read.stats("weight")
      assert_equal writer.activity_records, read.activity_records
      assert_equal 1, read.schema_history(created["dataset_id"]).length
      %i[create insert update delete migrate import_rows database].each { |name| refute read.respond_to?(name) }
      assert_raises(StructuredDataset::InvalidQuery) { read.query("weight", where: "1=1 OR 1=1") }
    end
  end

  def test_readonly_connection_refuses_writes_and_reads_current_wal_snapshot
    with_schema_vault do |root|
      writer = dataset_engine(root)
      writer.create("weight")
      writer.database.with_connection do |connection|
        writer.insert("weight", { observed_at: "2026-10-25T12:00:00Z", weight_kg: 71.5 })
        read = reader(root)
        read.with_consistent_read do
          assert_equal 1, read.query("weight").length
          writer.insert("weight", { observed_at: "2026-10-26T12:00:00Z", weight_kg: 72.0 })
          assert_equal 1, read.query("weight").length
        end
        assert_equal 2, read.query("weight").length
        assert_equal 3, connection.get_first_value("PRAGMA user_version")
      end
      writer.database.with_read_connection do |connection|
        assert_raises(SQLite3::ReadOnlyException) { connection.execute("DELETE FROM weight") }
      end
      assert_equal 2, writer.query("weight").length
    end
  end

  def test_explicit_override_and_unavailable_activity_do_not_touch_default_storage
    with_schema_vault do |root|
      with_vault do |external|
        override = File.join(external, "rows.sqlite3")
        StructuredDataset::Engine.new(vault_root: root, database_path: override).create("weight")
        refute File.exist?(File.join(root, KnowledgeSDK::DATASET_PATH))
        assert_equal "ready", reader(root, override).availability["status"]
        timeline = KnowledgeActivity::Timeline.new(vault_root: root, dataset_reader: reader(root), cache: false)
        before = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort
        timeline.recent
        assert_includes timeline.source_warnings, "dataset_storage_missing"
        assert_equal before, Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort
      end
    end
  end

  def test_busy_storage_and_aborted_read_release_connections_without_repair
    with_schema_vault do |root|
      writer = dataset_engine(root)
      writer.create("weight")
      read = reader(root)
      lock = SQLite3::Database.new(writer.database.path.to_s)
      lock.execute("PRAGMA journal_mode = DELETE")
      lock.execute("BEGIN EXCLUSIVE")
      assert_equal "dataset_storage_unreadable", read.availability["code"]
      lock.execute("ROLLBACK")
      lock.close
      assert_raises(RuntimeError) { read.with_consistent_read { read.query("weight"); raise "synthetic abort" } }
      writer.insert("weight", { observed_at: "2026-10-25T12:00:00Z", weight_kg: 70.0 })
      assert_equal 1, read.query("weight").length
      assert_equal "ready", read.availability["status"]
    ensure
      lock&.close rescue nil
    end
  end
end
