# frozen_string_literal: true

require "timeout"

module AgentPlatform
  class Gateway
    attr_reader :registry, :sessions, :telemetry, :jobs, :policy

    def initialize(registry:, handlers:, policy:, sessions:, telemetry:, jobs:, services:,
                   clock: nil, id_generator: nil, schema_validator: SchemaValidator.new)
      @registry = registry
      @handlers = handlers
      @policy = policy
      @sessions = sessions
      @telemetry = telemetry
      @jobs = jobs
      @services = services
      @clock = clock || -> { Time.now }
      @id_generator = id_generator || KnowledgeGraph::IdGenerator.new(clock: @clock)
      @schema_validator = schema_validator
    end

    def discover(agent:, session_id: nil)
      session = session_id && sessions.fetch(session_id, agent_id: agent.id)
      registry.list.select do |manifest|
        @handlers.registered?(manifest) && policy.discoverable?(manifest, agent: agent, session: session)
      end.map { |manifest| registry.reference(manifest).to_h }.freeze
    end

    def plugin_registrar
      PluginRegistrar.new(registry: registry, handlers: @handlers)
    end

    def issue_request(invocation_token:, arguments:, session_id: nil, trace_id: nil)
      registry.fetch_token(invocation_token)
      AgentRequest.new(
        id: @id_generator.generate("request"), timestamp: @clock.call,
        capability_token: invocation_token, arguments: arguments,
        session_id: session_id, trace_id: trace_id || @id_generator.generate("trace")
      )
    end

    def execute(request:, agent:)
      raise InvalidRequest, "Gateway accepts AgentRequest objects only" unless request.is_a?(AgentRequest)

      started = monotonic
      manifest = registry.fetch_token(request.capability_token)
      session = request.session_id && sessions.fetch(request.session_id, agent_id: agent.id)
      @schema_validator.validate!(manifest.input_schema, request.arguments, label: "capability arguments")
      decision = policy.evaluate(manifest, agent: agent, session: session, arguments: request.arguments)
      telemetry.record("policy_decision", base_telemetry(request, agent, manifest).merge(
        policy_allowed: decision.allowed?, approval: decision.approval
      ))
      raise PolicyDenied, decision.reason unless decision.allowed?

      if manifest.asynchronous?
        job = jobs.submit(agent_id: agent.id, capability_id: manifest.capability_id) do
          execute_handler(request, agent, session, manifest)
        end
        telemetry.record("job_submitted", base_telemetry(request, agent, manifest).merge(job_id: job.id))
        return AgentResponse.new(
          status: "accepted", payload: { job_id: job.id, status: "queued" },
          request_id: request.id, trace_id: request.trace_id,
          capability_id: manifest.capability_id, capability_version: manifest.version,
          execution_time_ms: elapsed_ms(started)
        )
      end

      execute_handler(request, agent, session, manifest, started: started)
    rescue AgentPlatform::Error => error
      error_response(error, request, agent, manifest, started)
    rescue StandardError => error
      wrapped = ExecutionFailed.new("capability execution failed", details: { cause: error.class.name })
      error_response(wrapped, request, agent, manifest, started)
    end

    def execute!(request:, agent:)
      response = execute(request: request, agent: agent)
      return response if response.success?

      first = response.errors.first || {}
      code = first["code"].to_s
      error_class = AgentPlatform.const_defined?(code, false) ? AgentPlatform.const_get(code, false) : ExecutionFailed
      error_class = ExecutionFailed unless error_class.is_a?(Class) && error_class <= AgentPlatform::Error
      raise error_class.new(first["message"] || "capability execution failed", details: first["details"] || {})
    end

    def job_status(job_id:, agent:, wait_ms: nil)
      return jobs.wait(job_id, agent_id: agent.id, timeout_ms: wait_ms) if wait_ms

      jobs.fetch(job_id, agent_id: agent.id).to_h
    end

    def explain_trace(trace_id:, agent:)
      events = telemetry.trace(trace_id)
      allowed = events.any? { |event| event["agent_id"] == agent.id }
      raise PolicyDenied, "trace belongs to another agent" unless allowed || agent.permits?("telemetry:read_all")

      { trace_id: trace_id.to_s, events: events }
    end

    def policy_check(invocation_token:, arguments:, agent:, session_id: nil)
      manifest = registry.fetch_token(invocation_token)
      session = session_id && sessions.fetch(session_id, agent_id: agent.id)
      policy.evaluate(manifest, agent: agent, session: session, arguments: Value.immutable(arguments)).to_h
    end

    private

    def execute_handler(request, agent, session, manifest, started: nil)
      started ||= monotonic
      handler = @handlers.fetch(manifest)
      context = ExecutionContext.new(
        agent: agent, session: session, request: request, manifest: manifest, services: @services
      )
      result = nil
      ::Timeout.timeout(manifest.timeout_ms.to_f / 1_000.0) do
        result = handler.call(request.arguments, context)
      end
      result = HandlerResult.new(payload: result) if result.is_a?(Hash)
      raise ExecutionFailed, "capability handler returned an invalid result" unless result.is_a?(HandlerResult)
      if manifest.reasoning? && result.why.to_s.empty?
        raise OutputValidationFailed, "reasoning capability omitted why"
      end
      @schema_validator.validate!(
        manifest.output_schema, result.payload,
        error_class: OutputValidationFailed, label: "capability output"
      )
      SecurityGuard.validate_public!(result.payload)
      SecurityGuard.validate_public!(result.evidence, "evidence")
      response = AgentResponse.new(
        status: "succeeded", payload: result.payload, warnings: result.warnings,
        errors: [], evidence: result.evidence, why: result.why,
        confidence: result.confidence, graph_path: result.graph_path,
        request_id: request.id, trace_id: request.trace_id,
        capability_id: manifest.capability_id, capability_version: manifest.version,
        execution_time_ms: elapsed_ms(started)
      )
      telemetry.record("capability_completed", base_telemetry(request, agent, manifest).merge(
        status: response.status, duration_ms: response.execution_time_ms
      ))
      response
    rescue ::Timeout::Error
      raise Timeout, "capability exceeded its manifest timeout"
    end

    def error_response(error, request, agent, manifest, started)
      status = case error
               when PolicyDenied then "denied"
               when ApprovalRequired then "approval_required"
               when InvalidArguments, InvalidRequest then "invalid_request"
               else "error"
               end
      error_hash = { code: error.code, message: error.message, details: error.details }
      response = AgentResponse.new(
        status: status, payload: {}, errors: [error_hash], request_id: request.respond_to?(:id) ? request.id : "",
        trace_id: request.respond_to?(:trace_id) ? request.trace_id : "",
        capability_id: manifest && manifest.capability_id,
        capability_version: manifest && manifest.version,
        execution_time_ms: started ? elapsed_ms(started) : 0
      )
      if request.respond_to?(:trace_id) && agent
        telemetry.record("capability_failed", base_telemetry(request, agent, manifest).merge(
          status: status, error_code: error.code, duration_ms: response.execution_time_ms
        ))
      end
      response
    end

    def base_telemetry(request, agent, manifest)
      {
        trace_id: request.trace_id, request_id: request.id, session_id: request.session_id,
        agent_id: agent.id, capability_id: manifest && manifest.capability_id,
        capability_version: manifest && manifest.version
      }
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started)
      (monotonic - started) * 1_000.0
    end
  end
end
