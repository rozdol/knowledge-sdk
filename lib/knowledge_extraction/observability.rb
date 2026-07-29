# frozen_string_literal: true

require "json"

module KnowledgeExtraction
  class StructuredLogger
    SECRET_PATTERN = /(?:bearer\s+[a-z0-9._~+\/-]+=*|sk-[a-z0-9_-]{16,}|api[_-]?key\s*[:=]\s*\S+)/i.freeze

    def initialize(io: nil)
      @io = io
    end

    def emit(event, attributes = {})
      return unless @io

      safe = attributes.each_with_object({}) do |(key, value), result|
        result[key.to_s] = redact(value)
      end
      @io.puts(JSON.generate({ event: event.to_s }.merge(safe)))
    end

    private

    def redact(value)
      case value
      when String then value.gsub(SECRET_PATTERN, "[REDACTED]")
      when Hash then value.transform_values { |item| redact(item) }
      when Array then value.map { |item| redact(item) }
      else value
      end
    end
  end

  class StageMetrics
    attr_reader :values

    def initialize(clock: nil)
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @values = {}
    end

    def measure(stage)
      started = @clock.call
      result = yield
      @values["#{stage}_duration_ms"] = ((@clock.call - started) * 1_000).round(3)
      result
    rescue StandardError
      @values["#{stage}_duration_ms"] = ((@clock.call - started) * 1_000).round(3)
      @values["#{stage}_errors"] = @values.fetch("#{stage}_errors", 0) + 1
      raise
    end

    def merge!(attributes)
      attributes.each { |key, value| @values[key.to_s] = value }
      self
    end

    def to_h
      @values.sort.to_h.freeze
    end
  end
end
