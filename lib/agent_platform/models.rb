# frozen_string_literal: true

module AgentPlatform
  class AgentIdentity
    attr_reader :id, :permissions, :roles, :attributes

    def initialize(id:, permissions:, roles: [], attributes: {})
      @id = Value.required_string(id, "agent id", maximum: 200)
      @permissions = Array(permissions).map(&:to_s).uniq.sort.freeze
      @roles = Array(roles).map(&:to_s).uniq.sort.freeze
      @attributes = Value.immutable(attributes || {})
      freeze
    end

    def permits?(permission)
      requested = permission.to_s
      permissions.include?("*") || permissions.include?(requested) || permissions.any? do |granted|
        granted.end_with?("*") && requested.start_with?(granted[0...-1])
      end
    end
  end

  class AgentRequest
    attr_reader :id, :timestamp, :capability_token, :arguments, :session_id, :trace_id

    def initialize(id:, timestamp:, capability_token:, arguments:, trace_id:, session_id: nil)
      @id = Value.required_string(id, "request id", maximum: 200)
      @timestamp = normalize_time(timestamp)
      @capability_token = Value.required_string(capability_token, "capability token", maximum: 200)
      raise InvalidRequest, "arguments must be an object" unless arguments.is_a?(Hash)

      @arguments = Value.immutable(arguments)
      @session_id = session_id && Value.required_string(session_id, "session id", maximum: 200)
      @trace_id = Value.required_string(trace_id, "trace id", maximum: 200)
      freeze
    rescue ArgumentError => error
      raise InvalidRequest, error.message
    end

    def to_h
      {
        id: id, timestamp: timestamp, capability_token: capability_token,
        arguments: arguments, session_id: session_id, trace_id: trace_id
      }.reject { |_key, value| value.nil? }
    end

    private

    def normalize_time(value)
      return value.iso8601.freeze if value.respond_to?(:iso8601)

      Time.iso8601(value.to_s).iso8601.freeze
    rescue ArgumentError
      raise InvalidRequest, "timestamp must be ISO 8601"
    end
  end

  class HandlerResult
    attr_reader :payload, :warnings, :evidence, :why, :confidence, :graph_path

    def initialize(payload:, warnings: [], evidence: [], why: nil, confidence: nil, graph_path: [])
      raise ExecutionFailed, "capability payload must be an object" unless payload.is_a?(Hash)

      @payload = Value.immutable(payload)
      @warnings = Array(warnings).map(&:to_s).freeze
      @evidence = Value.immutable(evidence || [])
      @why = why && why.to_s.freeze
      @confidence = confidence.nil? ? nil : [[confidence.to_f, 0.0].max, 1.0].min.round(6)
      @graph_path = Array(graph_path).map(&:to_s).freeze
      freeze
    end
  end

  class AgentResponse
    attr_reader :status, :payload, :warnings, :errors, :evidence, :execution_time_ms,
                :capability_id, :capability_version, :request_id, :trace_id,
                :why, :confidence, :graph_path

    def initialize(status:, payload:, request_id:, trace_id:, capability_id: nil,
                   capability_version: nil, warnings: [], errors: [], evidence: [],
                   execution_time_ms: 0.0, why: nil, confidence: nil, graph_path: [])
      @status = status.to_s.freeze
      @payload = Value.immutable(payload || {})
      @warnings = Array(warnings).map(&:to_s).freeze
      @errors = Value.immutable(errors || [])
      @evidence = Value.immutable(evidence || [])
      @execution_time_ms = execution_time_ms.to_f.round(3)
      @capability_id = capability_id && capability_id.to_s.freeze
      @capability_version = capability_version && capability_version.to_s.freeze
      @request_id = request_id.to_s.freeze
      @trace_id = trace_id.to_s.freeze
      @why = why && why.to_s.freeze
      @confidence = confidence
      @graph_path = Array(graph_path).map(&:to_s).freeze
      freeze
    end

    def success?
      %w[succeeded accepted].include?(status)
    end

    def to_h
      {
        status: status, payload: payload, warnings: warnings, errors: errors,
        evidence: evidence, execution_time_ms: execution_time_ms,
        capability_id: capability_id, capability_version: capability_version,
        request_id: request_id, trace_id: trace_id, why: why,
        confidence: confidence, graph_path: graph_path
      }.reject { |_key, value| value.nil? }
    end
  end

  class ExecutionContext
    attr_reader :agent, :session, :request, :manifest, :services

    def initialize(agent:, session:, request:, manifest:, services:)
      @agent = agent
      @session = session
      @request = request
      @manifest = manifest
      @services = services
      @memo = {}
    end

    def memoize(key)
      return @memo[key] if @memo.key?(key)

      @memo[key] = yield
    end
  end
end
