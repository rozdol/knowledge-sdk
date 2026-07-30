# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

module AgentPlatform
  class CapabilityManifest
    MANIFEST_SCHEMA = "1.0.0".freeze
    ID_PATTERN = /\A[a-z][a-z0-9]*(?:\.[a-z][a-z0-9_]*)+\z/.freeze
    VERSION_PATTERN = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?\z/.freeze
    REQUIRED = %w[
      manifest_schema_version capability_id name version description input_schema output_schema
      errors execution policy explanation transports examples deprecation
    ].freeze

    attr_reader :data, :digest

    def initialize(data, schema_validator: SchemaValidator.new)
      normalized = Value.mutable(data)
      validate_manifest!(normalized, schema_validator)
      @data = Value.immutable(normalized)
      @digest = Digest::SHA256.hexdigest(Value.canonical_json(@data)).freeze
      freeze
    end

    def manifest_schema_version
      data.fetch("manifest_schema_version")
    end

    def capability_id
      data.fetch("capability_id")
    end

    def name
      data.fetch("name")
    end

    def version
      data.fetch("version")
    end

    def description
      data.fetch("description")
    end

    def input_schema
      data.fetch("input_schema")
    end

    def output_schema
      data.fetch("output_schema")
    end

    def execution
      data.fetch("execution")
    end

    def policy
      data.fetch("policy")
    end

    def asynchronous?
      execution.fetch("mode") == "asynchronous"
    end

    def effects
      execution.fetch("effects")
    end

    def timeout_ms
      execution.fetch("timeout_ms")
    end

    def permissions
      policy.fetch("permissions")
    end

    def risk
      policy.fetch("risk")
    end

    def approval
      policy.fetch("approval")
    end

    def reasoning?
      data.fetch("explanation").fetch("required")
    end

    def public_contract
      Value.mutable(data).merge("manifest_digest" => digest)
    end

    private

    def validate_manifest!(value, schema_validator)
      raise InvalidManifest, "manifest must be a JSON object" unless value.is_a?(Hash)

      missing = REQUIRED.reject { |field| value.key?(field) }
      raise InvalidManifest, "manifest missing fields: #{missing.join(', ')}" unless missing.empty?
      unless value["manifest_schema_version"] == MANIFEST_SCHEMA
        raise InvalidManifest, "unsupported manifest schema #{value['manifest_schema_version'].inspect}"
      end
      unless value["capability_id"].to_s.match?(ID_PATTERN)
        raise InvalidManifest, "invalid capability_id"
      end
      unless value["version"].to_s.match?(VERSION_PATTERN)
        raise InvalidManifest, "invalid capability version"
      end
      Value.required_string(value["name"], "name", maximum: 100)
      Value.required_string(value["description"], "description", maximum: 2_000)
      validate_schema_shape!(value["input_schema"], "input_schema")
      validate_schema_shape!(value["output_schema"], "output_schema")
      validate_schema_tree!(value["input_schema"], "input_schema")
      validate_schema_tree!(value["output_schema"], "output_schema")
      validate_execution!(value["execution"])
      validate_policy!(value["policy"])
      validate_explanation!(value["explanation"])
      validate_string_array!(value["errors"], "errors", allow_empty: false)
      validate_string_array!(value["transports"], "transports", allow_empty: false)
      raise InvalidManifest, "examples must be a non-empty array" unless value["examples"].is_a?(Array) && !value["examples"].empty?
      raise InvalidManifest, "deprecation must be an object" unless value["deprecation"].is_a?(Hash)
      unless %w[active deprecated removed].include?(value["deprecation"]["status"])
        raise InvalidManifest, "invalid deprecation status"
      end
      value["examples"].each_with_index do |example, index|
        unless example.is_a?(Hash) && example["arguments"].is_a?(Hash)
          raise InvalidManifest, "example #{index} must contain arguments"
        end
        schema_validator.validate!(
          value["input_schema"], example["arguments"],
          error_class: InvalidManifest, label: "example #{index} arguments"
        )
      end
    rescue ArgumentError => error
      raise InvalidManifest, error.message
    end

    def validate_schema_shape!(schema, field)
      unless schema.is_a?(Hash) && schema["type"]
        raise InvalidManifest, "#{field} must be a typed JSON Schema object"
      end
    end

    def validate_schema_tree!(schema, field)
      allowed_types = %w[object array string integer number boolean null]
      types = Array(schema["type"])
      unknown = types - allowed_types
      raise InvalidManifest, "#{field} has unsupported types: #{unknown.join(', ')}" unless unknown.empty?
      Regexp.new(schema["pattern"]) if schema["pattern"]
      schema.fetch("properties", {}).each do |name, child|
        validate_schema_shape!(child, "#{field}.properties.#{name}")
        validate_schema_tree!(child, "#{field}.properties.#{name}")
      end
      if schema["items"]
        validate_schema_shape!(schema["items"], "#{field}.items")
        validate_schema_tree!(schema["items"], "#{field}.items")
      end
    rescue RegexpError => error
      raise InvalidManifest, "#{field} has invalid pattern: #{error.message}"
    end

    def validate_execution!(execution)
      raise InvalidManifest, "execution must be an object" unless execution.is_a?(Hash)
      unless %w[synchronous asynchronous].include?(execution["mode"])
        raise InvalidManifest, "invalid execution mode"
      end
      unless %w[read_only operational_write proposal_write graph_write].include?(execution["effects"])
        raise InvalidManifest, "invalid execution effects"
      end
      timeout = execution["timeout_ms"]
      raise InvalidManifest, "timeout_ms must be between 1 and 300000" unless timeout.is_a?(Integer) && timeout.between?(1, 300_000)
      unless execution["idempotent"] == true || execution["idempotent"] == false
        raise InvalidManifest, "idempotent must be boolean"
      end
    end

    def validate_policy!(policy)
      raise InvalidManifest, "policy must be an object" unless policy.is_a?(Hash)
      validate_string_array!(policy["permissions"], "policy.permissions", allow_empty: true)
      raise InvalidManifest, "invalid risk" unless %w[low medium high].include?(policy["risk"])
      unless %w[none proposal_only existing_proposal_approval].include?(policy["approval"])
        raise InvalidManifest, "invalid approval policy"
      end
      if policy["approval"] == "existing_proposal_approval" && policy["proposal_id_argument"].to_s.empty?
        raise InvalidManifest, "proposal_id_argument is required for approval-gated capabilities"
      end
    end

    def validate_explanation!(explanation)
      unless explanation.is_a?(Hash) && [true, false].include?(explanation["required"])
        raise InvalidManifest, "explanation.required must be boolean"
      end
    end

    def validate_string_array!(value, field, allow_empty:)
      valid = value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? }
      valid &&= !value.empty? unless allow_empty
      raise InvalidManifest, "#{field} must be #{allow_empty ? 'an' : 'a non-empty'} array of strings" unless valid
    end
  end

  class ManifestLoader
    def load(paths)
      files = Array(paths).flat_map { |path| expand(path) }.uniq.sort
      raise InvalidManifest, "no capability manifest files found" if files.empty?

      files.flat_map { |file| load_file(file) }.freeze
    end

    private

    def expand(path)
      candidate = Pathname.new(path)
      return Dir[candidate.join("**/*.json").to_s] if candidate.directory?
      return [candidate.to_s] if candidate.file?

      []
    end

    def load_file(path)
      payload = JSON.parse(Pathname.new(path).read)
      Array(payload.is_a?(Array) ? payload : [payload]).map { |item| CapabilityManifest.new(item) }
    rescue JSON::ParserError => error
      raise InvalidManifest, "invalid JSON manifest #{Pathname.new(path).basename}: #{error.message}"
    rescue Errno::ENOENT, Errno::EACCES => error
      raise InvalidManifest, "manifest cannot be read: #{error.message}"
    end
  end

  module ManifestCompatibility
    module_function

    def validate!(previous, current)
      unless previous.capability_id == current.capability_id
        raise IncompatibleVersion, "capability IDs differ"
      end
      old_version = version_parts(previous.version)
      new_version = version_parts(current.version)
      raise IncompatibleVersion, "version must increase" unless (new_version <=> old_version) == 1
      return true if new_version.first > old_version.first

      old_required = Array(previous.input_schema["required"])
      new_required = Array(current.input_schema["required"])
      added_required = new_required - old_required
      unless added_required.empty?
        raise IncompatibleVersion, "adding required inputs requires a major version"
      end
      removed_outputs = previous.output_schema.fetch("properties", {}).keys -
                        current.output_schema.fetch("properties", {}).keys
      unless removed_outputs.empty?
        raise IncompatibleVersion, "removing outputs requires a major version"
      end
      true
    end

    def version_parts(version)
      version.split("-", 2).first.split(".").map(&:to_i)
    end
  end
end
