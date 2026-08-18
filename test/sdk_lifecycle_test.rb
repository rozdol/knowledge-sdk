# frozen_string_literal: true

require "json"
require "stringio"
require_relative "test_helper"

class SDKLifecycleTest < Minitest::Test
  def test_attach_registers_arbitrary_obsidian_vault_without_modifying_it
    with_vault do |vault|
      FileUtils.mkdir_p(File.join(vault, ".obsidian"))
      File.write(File.join(vault, "note.md"), "# Plain note\n")
      before = snapshot(vault)

      with_config do |config_path|
        registry = KnowledgeSDK::VaultRegistry.new(configuration: KnowledgeSDK::Configuration.new(path: config_path))
        record = registry.attach(vault, name: "Research")

        assert_equal "Research", record.fetch("name")
        assert_nil record["profile"]
        assert_equal before, snapshot(vault)
        assert_equal File.realpath(vault), registry.current.fetch("path")
      end
    end
  end

  def test_locator_precedence_is_explicit_environment_upward_then_active
    Dir.mktmpdir("knowledge-sdk-locator-") do |root|
      explicit = create_obsidian_vault(root, "explicit")
      environment = create_obsidian_vault(root, "environment")
      discovered = create_obsidian_vault(root, "discovered")
      nested = File.join(discovered, "notes/deep")
      FileUtils.mkdir_p(nested)
      active = create_obsidian_vault(root, "active")

      with_config do |config_path|
        registry = KnowledgeSDK::VaultRegistry.new(configuration: KnowledgeSDK::Configuration.new(path: config_path))
        registry.attach(active)
        locator = KnowledgeSDK::VaultLocator.new(
          registry: registry, cwd: nested, environment: { "KG_VAULT" => environment }
        )
        assert_equal File.realpath(explicit), locator.resolve(explicit: explicit).path.to_s
        assert_equal File.realpath(environment), locator.resolve.path.to_s

        upward = KnowledgeSDK::VaultLocator.new(registry: registry, cwd: nested, environment: {})
        assert_equal File.realpath(discovered), upward.resolve.path.to_s

        configured = KnowledgeSDK::VaultLocator.new(registry: registry, cwd: root, environment: {})
        assert_equal File.realpath(active), configured.resolve.path.to_s
      end
    end
  end

  def test_multi_vault_cli_and_detach_do_not_modify_vault
    Dir.mktmpdir("knowledge-sdk-multi-") do |root|
      first = create_obsidian_vault(root, "Personal")
      second = create_obsidian_vault(root, "Research")
      with_config do |config_path|
        assert_cli(0, ["--config", config_path, "attach", first])
        assert_cli(0, ["--config", config_path, "attach", second])
        status, output, = run_cli(["--config", config_path, "vault", "list"])
        assert_equal 0, status
        assert_equal 2, JSON.parse(output).fetch("vaults").length

        assert_cli(0, ["--config", config_path, "vault", "use", "Research"])
        before = snapshot(second)
        assert_cli(0, ["--config", config_path, "detach", second])
        assert_equal before, snapshot(second)
      end
    end
  end

  def test_version_and_id_commands_do_not_require_a_vault
    status, output, error = run_cli(["version"])
    assert_equal 0, status, error
    assert_equal "17.0.0", JSON.parse(output).fetch("version")

    status, output, error = run_cli(["id", "person"])
    assert_equal 0, status, error
    assert_match(/\Aperson_[0-9A-HJKMNP-TV-Z]{26}\n\z/, output)
  end

  def test_plugin_install_is_explicit_and_migration_removes_embedded_business_logic
    Dir.mktmpdir("knowledge-sdk-migration-") do |root|
      vault = create_obsidian_vault(root, "Legacy")
      FileUtils.mkdir_p(File.join(vault, "_System/KnowledgeGraph/Runtime"))
      FileUtils.mkdir_p(File.join(vault, "_System/KnowledgeGraph/lib"))
      FileUtils.mkdir_p(File.join(vault, "_System/Tools"))
      File.write(File.join(vault, "_System/KnowledgeGraph/lib/legacy.rb"), "# legacy\n")
      File.write(File.join(vault, "_System/KnowledgeGraph/Runtime/audit.jsonl"), "{}\n")
      File.write(File.join(vault, "_System/KnowledgeGraph/Runtime/datasets.sqlite3"), "sqlite")
      File.write(File.join(vault, "_System/Tools/validate_vault.rb"), "# legacy\n")

      installed = KnowledgeSDK::PluginRegistry.new.install("personal-crm", vault)
      assert_operator installed.length, :>, 40

      backup_root = File.join(root, "backups")
      result = KnowledgeSDK::Migration.new(vault_root: vault, backup_root: backup_root)
                                      .migrate!(prune_embedded: true)
      assert File.file?(File.join(vault, ".knowledge/runtime/audit.jsonl"))
      assert File.file?(File.join(vault, ".knowledge/datasets.sqlite3"))
      refute File.exist?(File.join(vault, "_System/KnowledgeGraph"))
      refute File.exist?(File.join(vault, "_System/Tools"))
      assert File.file?(File.join(result.fetch("backup"), "manifest.json"))

      restored = KnowledgeSDK::Migration.new(vault_root: vault, backup_root: backup_root)
                                        .rollback!(result.fetch("backup"))
      assert_includes restored, "_System/KnowledgeGraph"
      assert File.file?(File.join(vault, "_System/KnowledgeGraph/lib/legacy.rb"))
      assert File.file?(File.join(vault, "_System/KnowledgeGraph/Runtime/audit.jsonl"))
      assert File.file?(File.join(vault, "_System/KnowledgeGraph/Runtime/datasets.sqlite3"))
      refute File.exist?(File.join(vault, ".knowledge/runtime"))
      refute File.exist?(File.join(vault, ".knowledge/datasets.sqlite3"))
    end
  end

  def test_runtime_and_dataset_state_live_under_data_only_knowledge_directory
    with_schema_vault do |vault|
      with_config do |config_path|
        KnowledgeSDK.dataset_path_override = nil
        database = StructuredDataset::Database.new(vault_root: vault)
        database.migrate!

        assert_equal File.join(vault, ".knowledge/datasets.sqlite3"), database.path.to_s
        refute File.exist?(File.join(vault, "_System/KnowledgeGraph"))

        File.write(config_path, "---\nversion: 1\nvaults: {}\ndataset_db: local/rows.sqlite3\n")
        configured = StructuredDataset::Database.new(vault_root: vault)
        assert_equal File.join(vault, "local/rows.sqlite3"), configured.path.to_s
      end
    end
  end

  private

  def with_config
    Dir.mktmpdir("knowledge-sdk-config-") do |root|
      old_path = KnowledgeSDK.config_path
      path = File.join(root, "config.yml")
      KnowledgeSDK.config_path = path
      yield path
    ensure
      KnowledgeSDK.config_path = old_path
    end
  end

  def create_obsidian_vault(root, name)
    path = File.join(root, name)
    FileUtils.mkdir_p(File.join(path, ".obsidian"))
    path
  end

  def snapshot(root)
    Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH).sort.map do |path|
      relative = path.delete_prefix(root + "/")
      [relative, File.file?(path) ? File.binread(path) : :directory]
    end
  end

  def run_cli(arguments)
    out = StringIO.new
    err = StringIO.new
    status = KnowledgeGraph::CLI.run(arguments, out: out, err: err)
    [status, out.string, err.string]
  end

  def assert_cli(expected, arguments)
    status, _output, error = run_cli(arguments)
    assert_equal expected, status, error
  end
end
