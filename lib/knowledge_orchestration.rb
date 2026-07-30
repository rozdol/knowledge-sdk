# frozen_string_literal: true

require_relative "knowledge_orchestration/errors"
require_relative "knowledge_orchestration/support"
require_relative "knowledge_orchestration/event"
require_relative "knowledge_orchestration/cache"
require_relative "knowledge_orchestration/workflow"
require_relative "knowledge_orchestration/runtime"
require_relative "knowledge_orchestration/scheduler"
require_relative "knowledge_orchestration/engine"
require_relative "knowledge_orchestration/cli"

module KnowledgeOrchestration
  VERSION = "9.0.0".freeze
  DEFAULT_WORKFLOW_PATH = File.expand_path("../config/workflows.yml", __dir__).freeze
  DEFAULT_SCHEDULE_PATH = File.expand_path("../config/schedules.yml", __dir__).freeze

  module_function

  def build(vault_root:, run_id: nil, actor_id: nil, clock: nil,
            workflow_paths: DEFAULT_WORKFLOW_PATH, schedule_path: DEFAULT_SCHEDULE_PATH,
            threaded_workflows: true, threaded_gateway_jobs: false)
    clock ||= -> { Time.now }
    resolved_run_id = run_id || KnowledgeGraph::IdGenerator.new(clock: clock).generate("run")
    event_registry = EventRegistry.default
    event_store = EventStore.new(vault_root: vault_root)
    dead_letters = DeadLetterStore.new(vault_root: vault_root, clock: clock)
    event_bus = EventBus.new(
      store: event_store, registry: event_registry, dead_letters: dead_letters,
      vault_root: vault_root, clock: clock
    )
    notifications = NotificationStore.new(vault_root: vault_root, clock: clock)
    gateway = AgentPlatform.build(
      vault_root: vault_root, run_id: resolved_run_id, actor_id: actor_id,
      clock: clock, threaded_jobs: threaded_gateway_jobs, event_bus: event_bus,
      notification_store: notifications
    )
    agent = AgentPlatform::AgentIdentity.new(
      id: actor_id.to_s.empty? ? "phase9-orchestrator" : actor_id.to_s,
      permissions: %w[
        graph:read intelligence:read planning:read proposal:create proposal:read
        notification:create
      ],
      roles: ["orchestrator"],
      attributes: {
        "autonomous_execution" => false,
        "denied_capabilities" => ["kg.proposals.submit"]
      }
    )
    definitions = WorkflowLoader.new.load(workflow_paths)
    workflow_registry = WorkflowRegistry.new(definitions)
    plugins = PluginRegistrar.new(
      event_registry: event_registry, workflow_registry: workflow_registry,
      capability_registrar: gateway.plugin_registrar
    )
    history = WorkflowHistoryStore.new(vault_root: vault_root)
    cache = KnowledgeCache.new(vault_root: vault_root, clock: clock)
    jobs = DurableJobManager.new(vault_root: vault_root, clock: clock, threaded: threaded_workflows)
    snapshot_provider = -> { KnowledgeIntelligence::GraphSnapshot.load(vault_root: vault_root) }
    workflow_engine = WorkflowEngine.new(
      invoker: GatewayInvoker.new(gateway: gateway, agent: agent), cache: cache,
      history: history, snapshot_provider: snapshot_provider, clock: clock,
      event_bus: event_bus
    )
    schedules = ScheduleLoader.new.load(schedule_path)
    scheduler = Scheduler.new(
      schedules: schedules, event_bus: event_bus, vault_root: vault_root, clock: clock
    )
    Orchestrator.new(
      event_bus: event_bus, workflow_registry: workflow_registry,
      workflow_engine: workflow_engine, scheduler: scheduler, jobs: jobs,
      history: history, cache: cache, notifications: notifications,
      snapshot_provider: snapshot_provider, plugins: plugins
    )
  end
end
