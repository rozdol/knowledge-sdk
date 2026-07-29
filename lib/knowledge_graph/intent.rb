# frozen_string_literal: true

module KnowledgeGraph
  class Intent
    NO_DEFAULT = Object.new.freeze
    attr_reader :intent_id

    class << self
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@field_definitions, field_definitions.dup)
      end

      def field(name, default: NO_DEFAULT)
        field_definitions[name.to_sym] = default
        attr_reader name
      end

      def field_definitions
        @field_definitions ||= { intent_id: nil }
      end
    end

    def initialize(**attributes)
      normalized = attributes.transform_keys(&:to_sym)
      unknown = normalized.keys - self.class.field_definitions.keys
      raise InvalidIntent, "unknown fields for #{intent_type}: #{unknown.join(', ')}" unless unknown.empty?

      self.class.field_definitions.each do |name, default|
        value = if normalized.key?(name)
                  normalized.fetch(name)
                elsif default.equal?(NO_DEFAULT)
                  raise InvalidIntent, "missing required field #{name} for #{intent_type}"
                else
                  materialize_default(default)
                end
        instance_variable_set("@#{name}", immutable_copy(value))
      end
      freeze
    end

    def intent_type
      self.class.name.split("::").last
    end

    def to_h
      self.class.field_definitions.keys.to_h { |name| [name, public_send(name)] }
        .merge(intent_type: intent_type)
        .freeze
    end

    def ==(other)
      other.instance_of?(self.class) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      [self.class, to_h].hash
    end

    private

    def materialize_default(default)
      default.respond_to?(:call) ? default.call : default
    end

    def immutable_copy(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), copy|
          copy[immutable_copy(key)] = immutable_copy(item)
        end.freeze
      when Array
        value.map { |item| immutable_copy(item) }.freeze
      when String
        value.dup.freeze
      else
        value.frozen? ? value : value.dup.freeze
      end
    rescue TypeError
      value.freeze
    end
  end
end
