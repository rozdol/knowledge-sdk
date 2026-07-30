# frozen_string_literal: true

require_relative "test_support"

class AgentPlatformManifestRegistryTest < Minitest::Test
  def test_core_manifests_are_valid_versioned_and_opaque
    manifests = AgentPlatform::ManifestLoader.new.load(AgentPlatform::DEFAULT_MANIFEST_PATH)
    registry = AgentPlatform::CapabilityRegistry.new(manifests)

    assert_equal 26, registry.size
    assert_equal manifests.map { |item| [item.capability_id, item.version] }.uniq.length, manifests.length
    reference = registry.reference_for("kg.entities.search")
    assert_match(/\Acap_[0-9a-f]{48}\z/, reference.invocation_token)
    refute_includes reference.to_h.keys, "handler"
    refute_equal reference.manifest.capability_id, reference.invocation_token
  end

  def test_manifest_rejects_missing_contract_and_duplicate_registration
    assert_raises(AgentPlatform::InvalidManifest) do
      AgentPlatform::CapabilityManifest.new("capability_id" => "kg.bad")
    end

    manifest = AgentPlatform::ManifestLoader.new.load(AgentPlatform::DEFAULT_MANIFEST_PATH).first
    registry = AgentPlatform::CapabilityRegistry.new([manifest])
    assert_raises(AgentPlatform::InvalidManifest) { registry.register(manifest) }
  end

  def test_compatibility_allows_optional_minor_change_and_rejects_required_input
    current = AgentPlatform::ManifestLoader.new.load(AgentPlatform::DEFAULT_MANIFEST_PATH).find do |item|
      item.capability_id == "kg.entities.search"
    end
    compatible = current.public_contract
    compatible.delete("manifest_digest")
    compatible["version"] = "1.1.0"
    compatible["input_schema"]["properties"]["locale"] = { "type" => "string" }
    assert AgentPlatform::ManifestCompatibility.validate!(
      current, AgentPlatform::CapabilityManifest.new(compatible)
    )

    incompatible = AgentPlatform::Value.mutable(compatible)
    incompatible["version"] = "1.2.0"
    incompatible["input_schema"]["required"] << "locale"
    incompatible["examples"].each { |example| example["arguments"]["locale"] = "en" }
    assert_raises(AgentPlatform::IncompatibleVersion) do
      AgentPlatform::ManifestCompatibility.validate!(
        AgentPlatform::CapabilityManifest.new(compatible),
        AgentPlatform::CapabilityManifest.new(incompatible)
      )
    end
  end

  def test_documentation_and_sdk_are_generated_from_manifests
    registry = AgentPlatform::CapabilityRegistry.new(
      AgentPlatform::ManifestLoader.new.load(AgentPlatform::DEFAULT_MANIFEST_PATH)
    )
    docs = AgentPlatform::Generators.markdown(registry)
    sdk = AgentPlatform::Generators.ruby_sdk(registry)

    assert_includes docs, "kg.entities.search@1.0.0"
    assert_includes docs, "kg.planning.plan@1.0.0"
    assert_includes sdk, "def search_entities"
    assert_includes sdk, "def plan_goal"
    assert_includes sdk, "kg.proposals.submit"
  end
end
