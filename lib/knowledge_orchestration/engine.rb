# frozen_string_literal: true

require "timeout"

module KnowledgeOrchestration
  class GatewayInvoker
    def initialize(gateway:, agent:)
      @gateway = gateway
      @agent = agent
    end

    def invoke(step, arguments, trace_id:)
      contract = contract_for(step)
      validate_automation_boundary!(contract)

      request = @gateway.issue_request(
        invocation_token: contract.fetch("invocation_token"), arguments: arguments,
        trace_id: trace_id
      )
      response = nil
      ::Timeout.timeout(step.timeout_seconds) do
        response = @gateway.execute(request: request, agent: @agent)
        response = wait_for_job(response, step.timeout_seconds) if response.status == "accepted"
      end
      unless response.success?
        error = response.errors.first || { "code" => "ExecutionFailed", "message" => "capability failed" }
        raise WorkflowExecutionFailed, "#{error['code']}: #{error['message']}"
      end
      {
        "payload" => AgentPlatform::Value.mutable(response.payload),
        "capability_version" => response.capability_version || contract.fetch("version"),
        "duration_ms" => response.execution_time_ms
      }
    rescue ::Timeout::Error
      raise WorkflowExecutionFailed, "workflow step #{step.id} timed out"
    end

    def version_for(step)
      contract = contract_for(step)
      validate_automation_boundary!(contract)
      contract.fetch("version")
    end

    private

    def contract_for(step)
      contract = @gateway.discover(agent: @agent).find do |item|
        item.fetch("capability_id") == step.capability_id &&
          (!step.capability_version || item.fetch("version") == step.capability_version)
      end
      raise WorkflowExecutionFailed, "workflow capability is unavailable: #{step.capability_id}" unless contract

      contract
    end

    def validate_automation_boundary!(contract)
      execution = contract.fetch("execution")
      policy = contract.fetch("policy")
      if execution.fetch("effects") == "graph_write" || policy.fetch("approval") == "existing_proposal_approval"
        raise WorkflowExecutionFailed, "workflow cannot automate approval-gated Engine execution"
      end
    end

    def wait_for_job(response, timeout_seconds)
      status = @gateway.job_status(
        job_id: response.payload.fetch("job_id"), agent: @agent,
        wait_ms: timeout_seconds * 1_000
      )
      unless status.fetch("status") == "succeeded"
        error = status["error"] || { "code" => "ExecutionFailed", "message" => "asynchronous job did not succeed" }
        return AgentPlatform::AgentResponse.new(
          status: "error", payload: {}, errors: [error], request_id: response.request_id,
          trace_id: response.trace_id, capability_id: response.capability_id,
          capability_version: response.capability_version
        )
      end
      result = status.fetch("result")
      AgentPlatform::AgentResponse.new(
        status: result.fetch("status"), payload: result.fetch("payload", {}),
        warnings: result.fetch("warnings", []), errors: result.fetch("errors", []),
        evidence: result.fetch("evidence", []), request_id: result.fetch("request_id"),
        trace_id: result.fetch("trace_id"), capability_id: result["capability_id"],
        capability_version: result["capability_version"],
        execution_time_ms: result.fetch("execution_time_ms", 0), why: result["why"],
        confidence: result["confidence"], graph_path: result.fetch("graph_path", [])
      )
    end
  end

  class WorkflowEngine
    COMPLETION_EVENTS = {
      "kg.intelligence.analyze" => "AnalyzerCompleted"
    }.freeze

    def initialize(invoker:, cache:, history:, snapshot_provider:, clock: nil,
                   event_bus: nil)
      @invoker = invoker
      @cache = cache
      @history = history
      @snapshot_provider = snapshot_provider
      @clock = clock || -> { Time.now }
      @event_bus = event_bus
    end

    def execute(workflow:, event:, replay: false, progress: nil)
      snapshot = @snapshot_provider.call
      snapshot_digest = snapshot.respond_to?(:digest) ? snapshot.digest : snapshot.to_s
      prior = @history.list(workflow_id: workflow.id).find do |execution|
        execution.workflow_version == workflow.version && execution.event.id == event.id
      end
      if replay && prior
        unless prior.workflow_digest == workflow.digest
          raise WorkflowExecutionFailed, "workflow definition changed since the original execution"
        end
        unless prior.snapshot_digest == snapshot_digest
          raise WorkflowExecutionFailed, "original immutable graph snapshot is not the current snapshot"
        end
      end
      execution_id = Stable.id("workflow-run", workflow.id, workflow.version, workflow.digest, event.id, snapshot_digest)
      existing = fetch_existing(execution_id)
      return existing if existing && !replay && existing.status == "succeeded"

      started_at = @clock.call
      step_results = []
      context = base_context(workflow, event, snapshot_digest)
      error = nil
      workflow.ordered_steps.each_with_index do |step, index|
        progress.call(progress_value(index, workflow.steps.length), retry_state(step_results)) if progress
        result = execute_step(step, context, event, snapshot_digest)
        step_results << result
        context.fetch("steps")[step.id] = result
        publish_completion(step, result, event, execution_id)
      rescue StandardError => step_error
        error = {
          "code" => step_error.class.name.split("::").last,
          "message" => safe_message(step_error.message), "step_id" => step.id
        }
        step_results << failed_step(step, step_error)
        break
      end

      status = error ? "failed" : "succeeded"
      outputs = error ? {} : TemplateResolver.resolve(workflow.outputs, context)
      logical = step_results.map do |step|
        {
          "step_id" => step["step_id"], "capability_id" => step["capability_id"],
          "capability_version" => step["capability_version"], "status" => step["status"],
          "payload" => step["payload"], "error" => step["error"]
        }.reject { |_key, value| value.nil? }
      end
      output_digest = Stable.digest("status" => status, "steps" => logical, "outputs" => outputs)
      if existing && replay && existing.output_digest != output_digest
        raise WorkflowExecutionFailed, "workflow replay diverged from the original execution"
      end
      return existing if existing && replay

      execution = WorkflowExecution.new(
        id: execution_id, workflow_id: workflow.id, workflow_version: workflow.version,
        workflow_digest: workflow.digest, event: event, snapshot_digest: snapshot_digest,
        trace_id: event.trace_id, status: status, steps: step_results, outputs: outputs,
        started_at: started_at, completed_at: @clock.call, output_digest: output_digest,
        error: error
      )
      @history.write(execution)
      raise WorkflowExecutionFailed, error.fetch("message") if error

      execution
    end

    private

    def execute_step(step, context, event, snapshot_digest)
      arguments = TemplateResolver.resolve(step.arguments, context)
      capability_version = if @invoker.respond_to?(:version_for)
                             @invoker.version_for(step)
                           else
                             step.capability_version || "latest"
                           end
      cache_key = @cache.key(
        capability_id: step.capability_id, capability_version: capability_version,
        arguments: arguments, snapshot_digest: snapshot_digest
      )
      if step.cache?
        cached = @cache.fetch(cache_key, snapshot_digest: snapshot_digest)
        return cached_result(step, @cache.record_reuse(cached, event_id: event.id)) if cached
      end

      attempts = 0
      invocation = nil
      started = monotonic
      begin
        attempts += 1
        invocation = @invoker.invoke(step, arguments, trace_id: event.trace_id)
      rescue WorkflowExecutionFailed
        retry if attempts <= step.retries
        raise
      end
      payload = invocation.fetch("payload")
      result = {
        "step_id" => step.id, "capability_id" => step.capability_id,
        "capability_version" => invocation.fetch("capability_version"),
        "status" => "succeeded", "payload" => payload, "attempts" => attempts,
        "duration_ms" => elapsed_ms(started), "cache_hit" => false,
        "output_digest" => Stable.digest(payload)
      }
      if step.cache?
        dependencies = ArtifactDependencies.new(
          event_ids: [event.id], event_types: step.cache.fetch("invalidate_on"),
          entity_ids: dependency_entity_ids(step, context, event),
          snapshot_digest: snapshot_digest, capability_id: step.capability_id,
          capability_version: invocation.fetch("capability_version")
        )
        artifact = @cache.write(
          artifact_type: step.artifact_type, cache_key: cache_key,
          value: { "payload" => payload }, dependencies: dependencies,
          metadata: { "workflow_id" => context.dig("workflow", "id"), "step_id" => step.id }
        )
        result["artifact_id"] = artifact.id
      end
      AgentPlatform::Value.immutable(result)
    end

    def cached_result(step, artifact)
      payload = AgentPlatform::Value.mutable(artifact.value.fetch("payload"))
      AgentPlatform::Value.immutable(
        "step_id" => step.id, "capability_id" => step.capability_id,
        "capability_version" => artifact.dependencies.capability_version,
        "status" => "succeeded", "payload" => payload, "attempts" => 0,
        "duration_ms" => 0.0, "cache_hit" => true, "artifact_id" => artifact.id,
        "output_digest" => Stable.digest(payload)
      )
    end

    def failed_step(step, error)
      AgentPlatform::Value.immutable(
        "step_id" => step.id, "capability_id" => step.capability_id,
        "capability_version" => step.capability_version,
        "status" => "failed", "payload" => {}, "attempts" => step.retries + 1,
        "duration_ms" => 0.0, "cache_hit" => false,
        "output_digest" => Stable.digest({}),
        "error" => {
          "code" => error.class.name.split("::").last,
          "message" => safe_message(error.message)
        }
      )
    end

    def base_context(workflow, event, snapshot_digest)
      {
        "event" => event.to_h.transform_keys(&:to_s),
        "workflow" => { "id" => workflow.id, "version" => workflow.version },
        "snapshot" => { "digest" => snapshot_digest }, "steps" => {}
      }
    end

    def dependency_entity_ids(step, context, event)
      explicit = step.cache.fetch("entity_paths").map { |path| TemplateResolver.lookup(context, path) }
      keys = %w[entity_id subject_id object_id person_id goal_id]
      direct = keys.map { |key| event.payload[key] }
      (explicit + direct + Array(event.payload["entity_ids"]) + Array(event.payload["changed_entity_ids"]))
        .flatten.compact.map(&:to_s).uniq.sort
    end

    def publish_completion(step, result, input_event, execution_id)
      type = if step.capability_id.start_with?("kg.planning.")
               "PlannerCompleted"
             else
               COMPLETION_EVENTS[step.capability_id]
             end
      return unless type && @event_bus && !result["cache_hit"]

      identifiers = %w[decision_id proposal_id].each_with_object({}) do |key, value|
        value[key] = result.fetch("payload")[key] if result.fetch("payload").key?(key)
      end
      @event_bus.publish(
        type: type, source: "workflow:#{execution_id}",
        payload: identifiers.merge("workflow_id" => execution_id, "step_id" => step.id),
        correlation_id: input_event.correlation_id, causation_id: input_event.id,
        trace_id: input_event.trace_id
      )
    end

    def fetch_existing(execution_id)
      @history.fetch(execution_id)
    rescue WorkflowNotFound
      nil
    end

    def progress_value(index, total)
      [((index.to_f / total) * 95).round, 1].max
    end

    def retry_state(step_results)
      step_results.each_with_object({}) do |step, result|
        result[step.fetch("step_id")] = { "attempts" => step.fetch("attempts") }
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started)
      ((monotonic - started) * 1_000.0).round(3)
    end

    def safe_message(value)
      value.to_s.gsub(%r{(?:/[^\s:]+)+}, "[path]")[0, 500]
    end
  end

  class Orchestrator
    attr_reader :event_bus, :workflow_registry, :trigger_engine, :workflow_engine,
                :scheduler, :jobs, :history, :cache, :notifications, :observability,
                :plugins

    def initialize(event_bus:, workflow_registry:, workflow_engine:, scheduler:, jobs:,
                   history:, cache:, notifications:, snapshot_provider:, plugins:)
      @event_bus = event_bus
      @workflow_registry = workflow_registry
      @trigger_engine = TriggerEngine.new(workflow_registry)
      @workflow_engine = workflow_engine
      @scheduler = scheduler
      @jobs = jobs
      @history = history
      @cache = cache
      @notifications = notifications
      @snapshot_provider = snapshot_provider
      @plugins = plugins
      @observability = Observability.new(
        history: history, event_store: event_bus.store, jobs: jobs, cache: cache
      )
      @event_bus.subscribe(id: "phase9-orchestrator") do |event, replay: false|
        handle_event(event, replay: replay)
      end
    end

    def publish(**attributes)
      event_bus.publish(**attributes)
    end

    def handle_event(event, replay: false)
      snapshot_digest = current_snapshot_digest
      cache.invalidate(event, new_snapshot_digest: snapshot_digest)
      trigger_engine.workflows_for(event).map do |workflow|
        if replay
          workflow_engine.execute(workflow: workflow, event: event, replay: true)
        else
          jobs.submit(event: event, workflow: workflow) do |progress|
            workflow_engine.execute(workflow: workflow, event: event, progress: progress)
          end
        end
      end.freeze
    end

    def run_workflow(workflow_id, payload: {}, source: "manual")
      workflow = workflow_registry.fetch(workflow_id)
      event_bus.publish(
        type: workflow.trigger_types.first, source: source,
        payload: payload.transform_keys(&:to_s).merge("_workflow" => workflow.id)
      )
    end

    def replay_event(event_id)
      event = event_bus.store.fetch(event_id)
      originals = history.list.select { |execution| execution.event.id == event.id }
      current = current_snapshot_digest
      if originals.any? { |execution| execution.snapshot_digest != current }
        raise WorkflowExecutionFailed, "original immutable graph snapshot is not the current snapshot"
      end
      event_bus.replay(event_id, subscriber_ids: ["phase9-orchestrator"])
      history.list.select { |execution| execution.event.id == event.id }.freeze
    end

    def replay_execution(execution_id)
      original = history.fetch(execution_id)
      unless original.snapshot_digest == current_snapshot_digest
        raise WorkflowExecutionFailed, "original immutable graph snapshot is not the current snapshot"
      end
      workflow = workflow_registry.fetch(original.workflow_id, version: original.workflow_version)
      replayed = workflow_engine.execute(workflow: workflow, event: original.event, replay: true)
      unless replayed.output_digest == original.output_digest
        raise WorkflowExecutionFailed, "workflow replay output differs"
      end
      replayed
    end

    def resume_jobs
      jobs.resumable.map do |job|
        data = job.to_h
        event = event_bus.store.fetch(data.fetch("event_id"))
        workflow = workflow_registry.fetch(data.fetch("workflow_id"), version: data.fetch("workflow_version"))
        jobs.submit(event: event, workflow: workflow, force: true) do |progress|
          workflow_engine.execute(workflow: workflow, event: event, progress: progress)
        end
      end.freeze
    end

    private

    def current_snapshot_digest
      snapshot = @snapshot_provider.call
      snapshot.respond_to?(:digest) ? snapshot.digest : snapshot.to_s
    end
  end

  class EngineEventBridge
    INTENT_EVENTS = {
      "AddRelationship" => "RelationshipUpdated", "RemoveRelationship" => "RelationshipUpdated",
      "ReplaceRelationship" => "RelationshipUpdated", "CompleteFollowUp" => "FollowupCompleted"
    }.freeze

    def initialize(event_bus:, source: "knowledge-graph-engine")
      @event_bus = event_bus
      @source = source
    end

    def attach(engine)
      engine.on(:after_commit) { |context| publish(context, engine.run_id) }
      engine
    end

    def publish(context, correlation_id)
      result = context.result
      return if result.replayed || result.changed_paths.empty?

      payload = {
        "intent_type" => context.intent.intent_type,
        "entity_ids" => result.entity_ids, "changed_paths_count" => result.changed_paths.length,
        "replayed" => result.replayed
      }
      base_type = capture_intent?(context.intent) ? "CaptureChanged" : "GraphChanged"
      graph_event = @event_bus.publish(
        type: base_type, source: @source, payload: payload,
        correlation_id: correlation_id
      )
      specific = specific_event(context.intent)
      return graph_event unless specific

      @event_bus.publish(
        type: specific, source: @source, payload: payload,
        correlation_id: graph_event.correlation_id, causation_id: graph_event.id,
        trace_id: graph_event.trace_id
      )
    end

    private

    def specific_event(intent)
      return "ContactCreated" if intent.intent_type == "CreateEntity" && intent.entity_type == "person"

      INTENT_EVENTS[intent.intent_type]
    end

    def capture_intent?(intent)
      %w[CreateCapture ReviewCapture LinkCapture PromoteCapture ArchiveCapture].include?(intent.intent_type)
    end
  end
end
