# frozen_string_literal: true

require_relative "test_support"

class AgentPlatformPerformanceTest < Minitest::Test
  def test_registry_dispatch_scales_to_hundreds_of_capabilities
    source = AgentPlatform::ManifestLoader.new.load(AgentPlatform::DEFAULT_MANIFEST_PATH).first
    registry = AgentPlatform::CapabilityRegistry.new
    handlers = AgentPlatform::HandlerRegistry.new
    count = ENV["AGENT_PLATFORM_FULL_PERFORMANCE"] == "1" ? 5_000 : 500
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    count.times do |index|
      data = source.public_contract
      data.delete("manifest_digest")
      data["capability_id"] = format("synthetic.capability_%04d", index)
      data["name"] = format("synthetic_%04d", index)
      data["description"] = "Synthetic registry scale fixture."
      data["policy"]["permissions"] = []
      manifest = AgentPlatform::CapabilityManifest.new(data)
      registry.register(manifest)
      handlers.register(manifest.capability_id) { |_arguments, _context| { ok: true } }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal count, registry.size
    assert_equal "synthetic.capability_0250", registry.fetch("synthetic.capability_0250").capability_id
    assert_operator elapsed, :<, ENV["AGENT_PLATFORM_FULL_PERFORMANCE"] == "1" ? 30.0 : 5.0
  end
end
