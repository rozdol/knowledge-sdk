# frozen_string_literal: true

require "thread"
require "time"

module AgentPlatform
  class TelemetryRecorder
    DEFAULT_LIMIT = 10_000
    ALLOWED_FIELDS = %w[
      timestamp event trace_id request_id session_id agent_id capability_id capability_version
      duration_ms cache_hits policy_allowed approval status error_code job_id
    ].freeze

    def initialize(clock: nil, limit: DEFAULT_LIMIT, sink: nil, ttl_seconds: nil)
      @clock = clock || -> { Time.now }
      @limit = Integer(limit)
      raise ArgumentError, "telemetry limit must be positive" unless @limit.positive?
      @sink = sink
      @ttl_seconds = ttl_seconds
      @events = []
      @mutex = Mutex.new
    end

    def record(event, attributes = {})
      safe = attributes.each_with_object({}) do |(key, value), result|
        name = key.to_s
        result[name] = scalar(value) if ALLOWED_FIELDS.include?(name)
      end
      safe["timestamp"] = @clock.call.iso8601
      safe["event"] = event.to_s
      immutable = Value.immutable(safe)
      @mutex.synchronize do
        prune!
        @events << immutable
        @events.shift while @events.length > @limit
      end
      @sink.call(immutable) if @sink
      immutable
    end

    def trace(trace_id)
      @mutex.synchronize { prune!; @events.select { |event| event["trace_id"] == trace_id.to_s }.dup.freeze }
    end

    def size
      @mutex.synchronize { prune!; @events.length }
    end

    private

    def prune!
      return unless @ttl_seconds

      cutoff = @clock.call - @ttl_seconds
      @events.reject! { |event| Time.iso8601(event.fetch("timestamp")) <= cutoff }
    end

    def scalar(value)
      case value
      when String, Numeric, TrueClass, FalseClass, NilClass then value
      else value.to_s
      end
    end
  end
end
