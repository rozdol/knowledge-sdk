# frozen_string_literal: true

require_relative "test_support"

class AgentPlatformJobsPluginsTest < Minitest::Test
  def test_opt_in_job_capacity_ttl_and_logout_cleanup
    now = FIXED_TIME
    jobs = AgentPlatform::JobManager.new(clock: -> { now }, threaded: false,
      limit: 2, per_agent_limit: 1, ttl_seconds: 600)
    first = jobs.submit(agent_id: "one", capability_id: "synthetic.read") { {} }
    assert_raises(AgentPlatform::ExecutionFailed) { jobs.submit(agent_id: "one", capability_id: "synthetic.read") { {} } }
    second = jobs.submit(agent_id: "two", capability_id: "synthetic.read") { {} }
    assert_raises(AgentPlatform::ExecutionFailed) { jobs.submit(agent_id: "three", capability_id: "synthetic.read") { {} } }
    now += 601
    assert_raises(AgentPlatform::JobNotFound) { jobs.fetch(first.id) }
    assert_raises(AgentPlatform::JobNotFound) { jobs.fetch(second.id) }
    active = jobs.submit(agent_id: "one", capability_id: "synthetic.read") { {} }
    jobs.remove_agent("one")
    assert_raises(AgentPlatform::JobNotFound) { jobs.fetch(active.id) }
  end

  def test_opt_in_telemetry_ttl_and_capacity
    now = FIXED_TIME
    recorder = AgentPlatform::TelemetryRecorder.new(clock: -> { now }, limit: 1, ttl_seconds: 600)
    recorder.record("test", trace_id: "old", password: "never retained")
    recorder.record("test", trace_id: "new")
    assert_empty recorder.trace("old")
    assert_equal 1, recorder.size
    now += 601
    assert_empty recorder.trace("new")
    assert_equal 0, recorder.size
  end

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
