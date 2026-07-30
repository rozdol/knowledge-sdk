# frozen_string_literal: true

module AgentPlatform
  module SecurityGuard
    FORBIDDEN_KEYS = %w[
      path relative_path changed_paths vault_root markdown raw_markdown handler implementation
      internal_class storage_adapter directory filesystem_path
    ].freeze

    module_function

    def validate_public!(value, location = "payload")
      case value
      when Hash
        value.each do |key, item|
          name = key.to_s
          if FORBIDDEN_KEYS.include?(name)
            raise SecurityViolation, "public #{location} contains a forbidden implementation field"
          end
          validate_public!(item, "#{location}.#{name}")
        end
      when Array
        value.each_with_index { |item, index| validate_public!(item, "#{location}[#{index}]") }
      end
      true
    end

    def sanitize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          next if FORBIDDEN_KEYS.include?(key.to_s)

          result[key.to_s] = sanitize(item)
        end
      when Array
        value.map { |item| sanitize(item) }
      else
        value
      end
    end
  end
end
