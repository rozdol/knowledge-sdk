# frozen_string_literal: true

require_relative "../../../test/test_helper"
require "knowledge_sdk/dashboard"

class DashboardSettingsTest < Minitest::Test
  def test_operator_files_grants_timezone_and_bind_bounds_fail_closed
    with_vault do |vault|
      with_vault do |operator|
        secret = File.join(operator, "secret")
        File.write(secret, SecureRandom.urlsafe_base64(32), mode: "w", perm: 0o600)
        base = { vault: vault, secret_file: secret, timezone: "Etc/UTC", config_path: File.join(operator, "absent.yml") }
        settings = KnowledgeSDK::Dashboard::Settings.new(**base)
        assert_equal File.join(File.realpath(vault), KnowledgeSDK::DATASET_PATH), settings.dataset_path
        assert_empty Dir.children(vault)
        assert_raises(KnowledgeSDK::ConfigurationError) { KnowledgeSDK::Dashboard::Settings.new(**base.merge(port: 80)) }
        assert_raises(KnowledgeSDK::ConfigurationError) { KnowledgeSDK::Dashboard::Settings.new(**base.merge(timezone: "invalid/zone")) }
        link = File.join(operator, "symlink")
        File.symlink(secret, link)
        assert_raises(KnowledgeSDK::ConfigurationError) { KnowledgeSDK::Dashboard::Settings.new(**base.merge(secret_file: link)) }
        inside = File.join(vault, "secret")
        File.write(inside, SecureRandom.urlsafe_base64(32), mode: "w", perm: 0o600)
        assert_raises(KnowledgeSDK::ConfigurationError) { KnowledgeSDK::Dashboard::Settings.new(**base.merge(secret_file: inside)) }
        File.chmod(0o644, secret)
        assert_raises(KnowledgeSDK::ConfigurationError) { KnowledgeSDK::Dashboard::Settings.new(**base) }
        File.chmod(0o600, secret)
        config = File.join(operator, "settings.json")
        File.write(config, JSON.generate(version: 1, permissions: ["*"]), mode: "w", perm: 0o600)
        assert_raises(KnowledgeSDK::ConfigurationError) { KnowledgeSDK::Dashboard::Settings.new(**base.merge(settings_file: config)) }
      end
    end
  end

  def test_relative_and_absolute_dataset_overrides_are_frozen_without_provisioning
    with_vault do |vault|
      with_vault do |operator|
        secret = File.join(operator, "secret")
        File.write(secret, SecureRandom.urlsafe_base64(32), mode: "w", perm: 0o600)
        base = { vault: vault, secret_file: secret, timezone: "Etc/UTC", config_path: File.join(operator, "absent.yml") }
        relative = KnowledgeSDK::Dashboard::Settings.new(**base.merge(dataset_path: "custom/rows.sqlite3"))
        absolute_path = File.join(operator, "external", "rows.sqlite3")
        absolute = KnowledgeSDK::Dashboard::Settings.new(**base.merge(dataset_path: absolute_path))
        assert_equal File.join(File.realpath(vault), "custom/rows.sqlite3"), relative.dataset_path
        assert_equal absolute_path, absolute.dataset_path
        assert_equal "dataset_storage_missing", absolute.reader.availability["code"]
        refute File.exist?(File.dirname(absolute_path))
        refute File.exist?(File.join(vault, "custom"))
      end
    end
  end

  def test_polling_does_not_extend_idle_and_foreground_activity_cannot_exceed_absolute_expiry
    now = Time.utc(2026, 10, 25)
    store = KnowledgeSDK::Dashboard::Sessions.new(clock: -> { now }, permissions: [], on_revoke: ->(_id) {})
    session = store.create(authenticated: true)
    17.times do
      now += 1700
      current = store.fetch(session[:id])
      break unless current
      store.touch(current)
    end
    assert_nil store.fetch(session[:id])
    fresh = store.create(authenticated: true)
    now += 1801
    assert_nil store.fetch(fresh[:id])
  end
end
