# frozen_string_literal: true

module AgentPlatform
  DEFAULT_MANIFEST_PATH = File.expand_path("../../config/agent_platform/manifests", __dir__).freeze

  module_function

  def build(vault_root:, run_id: nil, actor_id: nil, manifest_paths: DEFAULT_MANIFEST_PATH,
            environment: "production", feature_flags: {}, clock: nil, threaded_jobs: true,
            telemetry: nil, event_bus: nil, notification_store: nil)
    clock ||= -> { Time.now }
    id_generator = KnowledgeGraph::IdGenerator.new(clock: clock)
    resolved_run_id = run_id || id_generator.generate("run")
    services = Services.new(
      vault_root: vault_root, run_id: resolved_run_id, actor_id: actor_id, clock: clock,
      event_bus: event_bus, notification_store: notification_store
    )
    registry = CapabilityRegistry.new(ManifestLoader.new.load(manifest_paths))
    handlers = DefaultHandlers.build(services)
    approval_checker = lambda do |proposal_id|
      store = services.proposal_store
      proposal = store.load(proposal_id)
      approval = store.approval(proposal_id)
      approval && approval.fetch("proposal_fingerprint") == store.proposal_fingerprint(proposal)
    rescue KnowledgeExtraction::Error, KeyError
      false
    end
    policy = PolicyEngine.new(
      environment: environment, feature_flags: feature_flags,
      approval_checker: approval_checker
    )
    Gateway.new(
      registry: registry, handlers: handlers, policy: policy,
      sessions: SessionStore.new(clock: clock),
      telemetry: telemetry || TelemetryRecorder.new(clock: clock),
      jobs: JobManager.new(clock: clock, threaded: threaded_jobs),
      services: services, clock: clock
    )
  end

  def local_cli_identity(actor_id = nil)
    AgentIdentity.new(
      id: actor_id.to_s.empty? ? "local-cli" : actor_id.to_s,
      permissions: ["*"], roles: ["local_operator"], attributes: { "local" => true }
    )
  end
end
