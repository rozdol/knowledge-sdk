# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "time"

module KnowledgeExtraction
  module Support
    ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ".freeze
    module_function

    def deep_freeze(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), copy|
          copy[deep_freeze(key)] = deep_freeze(item)
        end.freeze
      when Array then value.map { |item| deep_freeze(item) }.freeze
      when String then value.dup.freeze
      else value.frozen? ? value : value.dup.freeze
      end
    rescue TypeError
      value.freeze
    end

    def canonical(value)
      value = value.to_h if defined?(ImmutableModel) && value.is_a?(ImmutableModel)
      case value
      when Hash
        value.keys.sort_by(&:to_s).each_with_object({}) do |key, result|
          result[key.to_s] = canonical(value.fetch(key))
        end
      when Array then value.map { |item| canonical(item) }
      when Time, Date then value.iso8601
      when Symbol then value.to_s
      else value
      end
    end

    def canonical_json(value)
      JSON.generate(canonical(value))
    end

    def parse_time(value, field: "time")
      return value if value.is_a?(Time)
      return nil if value.nil? || value.to_s.strip.empty?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      raise NormalizationFailure, "#{field} must be ISO 8601"
    end

    def stable_id(prefix, *parts)
      digest = Digest::SHA256.digest(parts.map(&:to_s).join("\u001f")).unpack1("H*").to_i(16)
      encoded = 26.times.map do
        character = ALPHABET[digest % 32]
        digest /= 32
        character
      end.reverse.join
      "#{prefix}_#{encoded}"
    end

    def deterministic_ulid(prefix, time, *parts)
      instant = parse_time(time, field: "ID timestamp") || Time.at(0).utc
      milliseconds = (instant.to_f * 1000).to_i & ((1 << 48) - 1)
      time_part = encode_base32(milliseconds, 10)
      random = Digest::SHA256.digest(parts.map(&:to_s).join("\u001f"))[0, 10].unpack1("H*").to_i(16)
      "#{prefix}_#{time_part}#{encode_base32(random, 16)}"
    end

    def encode_base32(number, length)
      length.times.map do
        character = ALPHABET[number % 32]
        number /= 32
        character
      end.reverse.join
    end

    def normalized_text(value)
      value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
           .unicode_normalize(:nfc).gsub("\r\n", "\n").gsub("\r", "\n").delete("\u0000")
    rescue Encoding::CompatibilityError
      raise NormalizationFailure, "source content could not be normalized as UTF-8"
    end

    def compact_hash(hash)
      hash.each_with_object({}) do |(key, value), result|
        result[key] = value unless value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
    end
  end

  class ImmutableModel
    def to_json(*arguments)
      JSON.generate(Support.canonical(to_h), *arguments)
    end

    private

    def immutable(value)
      Support.deep_freeze(value)
    end

    def required_string(value, field, maximum: 10_000)
      string = value.to_s
      raise ArgumentError, "#{field} is required" if string.strip.empty?
      raise ArgumentError, "#{field} exceeds #{maximum} characters" if string.length > maximum

      string.freeze
    end

    def optional_string(value, field, maximum: 10_000)
      return nil if value.nil?

      required_string(value, field, maximum: maximum)
    end

    def validated_confidence(value, field = "confidence")
      number = Float(value)
      raise ArgumentError, "#{field} must be between 0.0 and 1.0" unless number.between?(0.0, 1.0)

      number
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{field} must be between 0.0 and 1.0"
    end
  end
end
