# frozen_string_literal: true

require "date"
require "json"
require "time"

module AgentPlatform
  module Value
    module_function

    def immutable(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[key.to_s.dup.freeze] = immutable(item)
        end.freeze
      when Array
        value.map { |item| immutable(item) }.freeze
      when Time, DateTime
        value.iso8601.freeze
      when Date
        value.iso8601.freeze
      when String
        value.dup.freeze
      when Symbol
        value.to_s.freeze
      when Numeric, TrueClass, FalseClass, NilClass
        value.freeze
      else
        value.to_s.freeze
      end
    end

    def mutable(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = mutable(item) }
      when Array
        value.map { |item| mutable(item) }
      else
        value
      end
    end

    def canonical(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          result[key] = canonical(value[original])
        end
      when Array
        value.map { |item| canonical(item) }
      when Time, Date, DateTime
        value.iso8601
      when Symbol
        value.to_s
      else
        value
      end
    end

    def canonical_json(value)
      JSON.generate(canonical(value))
    end

    def required_string(value, field, maximum: 500)
      string = value.to_s
      if string.strip.empty? || string.length > maximum
        raise ArgumentError, "#{field} must be a non-empty string of at most #{maximum} characters"
      end

      string.freeze
    end
  end
end
