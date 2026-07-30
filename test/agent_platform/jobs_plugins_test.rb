# frozen_string_literal: true

require_relative "test_support"

class AgentPlatformJobsPluginsTest < Minitest::Test
  def test_async_network_job_has_bounded_status_protocol
    with_schema_vault do |root|
      create_base_entities(root)
      gateway, agent = build_gateway(root, permissions: ["intelligence:read"], threaded_jobs: false)
      response = invoke(gateway, agent, "kg.intelligence.network", { "as_of" => "2026-07-30" })

      assert_equal "accepted", response.status
      job = gateway.job_status(job_id: response.payload.fetch("job_id"), agent: agent)
      assert_equal "succeeded", job.fetch("status")
      assert_equal 100, job.fetch("progress")
      assert_equal "succeeded", job.fetch("result").fetch("status")
    end
  end

  def test_job_is_visible_only_to_its_owner
    with_schema_vault do |root|
      gateway, agent = build_gateway(root, permissions: ["intelligence:read"], threaded_jobs: false)
      response = invoke(gateway, agent, "kg.intelligence.network", {})
      another = AgentPlatform::AgentIdentity.new(id: "agent:other", permissions: ["intelligence:read"])

      assert_raises(AgentPlatform::PolicyDenied) do
        gateway.job_status(job_id: response.payload.fetch("job_id"), agent: another)
      end
    end
  end

  def test_plugin_registration_needs_manifest_and_explicit_trusted_handler
    base = AgentPlatform::ManifestLoader.new.load(AgentPlatform::DEFAULT_MANIFEST_PATH).first
    data = base.public_contract
    data.delete("manifest_digest")
    data["capability_id"] = "plugin.example.echo"
    data["name"] = "plugin_echo"
    data["description"] = "Synthetic plugin capability."
    data["policy"]["permissions"] = []
    data["input_schema"] = {
      "type" => "object", "required" => ["value"],
      "properties" => { "value" => { "type" => "string" } }, "additionalProperties" => false
    }
    data["output_schema"] = {
      "type" => "object", "required" => ["value"],
      "properties" => { "value" => { "type" => "string" } }, "additionalProperties" => false
    }
    data["examples"] = [{ "arguments" => { "value" => "synthetic" } }]
    manifest = AgentPlatform::CapabilityManifest.new(data)
    registry = AgentPlatform::CapabilityRegistry.new
    handlers = AgentPlatform::HandlerRegistry.new
    registrar = AgentPlatform::PluginRegistrar.new(registry: registry, handlers: handlers)
    registrar.register(
      manifest: manifest,
      handler: ->(arguments, _context) { AgentPlatform::HandlerResult.new(payload: { value: arguments.fetch("value") }) }
    )

    assert_equal manifest, registry.fetch("plugin.example.echo")
    assert handlers.registered?(manifest)
    assert_raises(AgentPlatform::HandlerNotRegistered) do
      registrar.load_manifests(AgentPlatform::DEFAULT_MANIFEST_PATH, handlers: {})
    end
  end
end
