# frozen_string_literal: true

require "date"
require "time"

module AgentPlatform
  class SchemaValidator
    def validate(schema, value, path = "$")
      errors = []
      check(schema, value, path, errors)
      errors.freeze
    end

    def validate!(schema, value, error_class: InvalidArguments, label: "value")
      errors = validate(schema, value)
      return true if errors.empty?

      raise error_class.new("#{label} does not match its schema", details: { errors: errors })
    end

    private

    def check(schema, value, path, errors)
      unless schema.is_a?(Hash)
        errors << "#{path}: schema must be an object"
        return
      end
      if schema.key?("oneOf")
        matches = schema.fetch("oneOf").count { |candidate| validate(candidate, value).empty? }
        errors << "#{path}: must match exactly one allowed schema" unless matches == 1
        return
      end
      if schema.key?("anyOf")
        matches = schema.fetch("anyOf").any? { |candidate| validate(candidate, value).empty? }
        errors << "#{path}: must match at least one allowed schema" unless matches
        return
      end
      if schema.key?("enum") && !schema.fetch("enum").include?(value)
        errors << "#{path}: is not an allowed value"
      end
      if schema.key?("const") && schema.fetch("const") != value
        errors << "#{path}: must equal the declared constant"
      end
      type = schema["type"]
      return if type.nil?

      allowed_types = Array(type)
      unless allowed_types.any? { |candidate| type_match?(candidate, value) }
        errors << "#{path}: expected #{allowed_types.join(' or ')}, got #{ruby_type(value)}"
        return
      end
      check_object(schema, value, path, errors) if value.is_a?(Hash)
      check_array(schema, value, path, errors) if value.is_a?(Array)
      check_string(schema, value, path, errors) if value.is_a?(String)
      check_number(schema, value, path, errors) if value.is_a?(Numeric)
    end

    def check_object(schema, value, path, errors)
      required = Array(schema["required"])
      missing = required.reject { |key| value.key?(key) || value.key?(key.to_sym) }
      errors << "#{path}: missing required properties #{missing.join(', ')}" unless missing.empty?
      properties = schema.fetch("properties", {})
      value.each do |key, item|
        name = key.to_s
        child = properties[name]
        if child
          check(child, item, "#{path}.#{name}", errors)
        elsif schema["additionalProperties"] == false
          errors << "#{path}: unknown property #{name}"
        elsif schema["additionalProperties"].is_a?(Hash)
          check(schema["additionalProperties"], item, "#{path}.#{name}", errors)
        end
      end
      if schema["minProperties"] && value.length < schema["minProperties"].to_i
        errors << "#{path}: has too few properties"
      end
      if schema["maxProperties"] && value.length > schema["maxProperties"].to_i
        errors << "#{path}: has too many properties"
      end
    end

    def check_array(schema, value, path, errors)
      if schema["minItems"] && value.length < schema["minItems"].to_i
        errors << "#{path}: has too few items"
      end
      if schema["maxItems"] && value.length > schema["maxItems"].to_i
        errors << "#{path}: has too many items"
      end
      errors << "#{path}: items must be unique" if schema["uniqueItems"] && value.uniq.length != value.length
      item_schema = schema["items"]
      value.each_with_index { |item, index| check(item_schema, item, "#{path}[#{index}]", errors) } if item_schema
    end

    def check_string(schema, value, path, errors)
      errors << "#{path}: is shorter than minLength" if schema["minLength"] && value.length < schema["minLength"].to_i
      errors << "#{path}: is longer than maxLength" if schema["maxLength"] && value.length > schema["maxLength"].to_i
      if schema["pattern"]
        expression = Regexp.new(schema["pattern"])
        errors << "#{path}: does not match the required pattern" unless value.match?(expression)
      end
      return unless schema["format"]

      valid = case schema["format"]
              when "date" then Date.iso8601(value)
              when "date-time" then Time.iso8601(value)
              else true
              end
      errors << "#{path}: has invalid #{schema['format']} format" unless valid
    rescue ArgumentError
      errors << "#{path}: has invalid #{schema['format']} format"
    end

    def check_number(schema, value, path, errors)
      errors << "#{path}: is below minimum" if schema.key?("minimum") && value < schema["minimum"]
      errors << "#{path}: is above maximum" if schema.key?("maximum") && value > schema["maximum"]
    end

    def type_match?(type, value)
      case type.to_s
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Numeric)
      when "boolean" then value == true || value == false
      when "null" then value.nil?
      else false
      end
    end

    def ruby_type(value)
      return "null" if value.nil?
      return "boolean" if value == true || value == false

      value.class.name
    end
  end
end
