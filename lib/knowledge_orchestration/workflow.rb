# frozen_string_literal: true

require "yaml"

module KnowledgeOrchestration
  class WorkflowStep
    ARTIFACT_TYPES = CachedArtifact::TYPES.freeze

    attr_reader :id, :capability_id, :capability_version, :arguments,
                :depends_on, :timeout_seconds, :retries, :cache

    def initialize(id:, capability:, arguments: {}, depends_on: [], timeout_seconds: 120,
                   retries: 0, cache: {})
      @id = identifier(id, "step id")
      selector = capability.to_s.split("@", 2)
      @capability_id = AgentPlatform::Value.required_string(selector.first, "capability id", maximum: 200)
      @capability_version = selector[1] && AgentPlatform::Value.required_string(selector[1], "capability version", maximum: 50)
      raise InvalidWorkflow, "step arguments must be an object" unless arguments.is_a?(Hash)
      @arguments = AgentPlatform::Value.immutable(arguments)
      @depends_on = Array(depends_on).map { |value| identifier(value, "step dependency") }.uniq.sort.freeze
      @timeout_seconds = Integer(timeout_seconds)
      raise InvalidWorkflow, "step timeout must be between 1 and 300 seconds" unless @timeout_seconds.between?(1, 300)
      @retries = Integer(retries)
      raise InvalidWorkflow, "step retries must be between 0 and 10" unless @retries.between?(0, 10)
      raise InvalidWorkflow, "step cache policy must be an object" unless cache.is_a?(Hash)
      @cache = normalize_cache(cache)
      freeze
    rescue ArgumentError, TypeError => error
      raise InvalidWorkflow, error.message
    end

    def cache?
      cache.fetch("enabled")
    end

    def artifact_type
      cache.fetch("artifact_type")
    end

    def to_h
      {
        id: id, capability: capability_version ? "#{capability_id}@#{capability_version}" : capability_id,
        arguments: arguments, depends_on: depends_on, timeout_seconds: timeout_seconds,
        retries: retries, cache: cache
      }
    end

    private

    def identifier(value, field)
      candidate = AgentPlatform::Value.required_string(value, field, maximum: 100)
      raise InvalidWorkflow, "invalid #{field}" unless candidate.match?(/\A[a-z][a-z0-9_-]*\z/)

      candidate
    end

    def normalize_cache(value)
      data = value.transform_keys(&:to_s)
      enabled = data.fetch("enabled", false) == true
      artifact_type = data.fetch("artifact_type", "workflow_output").to_s
      unless ARTIFACT_TYPES.include?(artifact_type)
        raise InvalidWorkflow, "invalid cache artifact type #{artifact_type.inspect}"
      end
      {
        "enabled" => enabled,
        "artifact_type" => artifact_type,
        "invalidate_on" => Array(data.fetch("invalidate_on", ["GraphChanged"])).map(&:to_s).uniq.sort,
        "entity_paths" => Array(data.fetch("entity_paths", [])).map(&:to_s).uniq.sort
      }.freeze
    end
  end

  class WorkflowCondition
    OPERATORS = %w[equals not_equals includes exists].freeze

    attr_reader :path, :operator, :value

    def initialize(path:, operator: "equals", value: nil)
      @path = AgentPlatform::Value.required_string(path, "condition path", maximum: 500)
      @operator = operator.to_s
      raise InvalidWorkflow, "unsupported condition operator #{@operator}" unless OPERATORS.include?(@operator)
      @value = AgentPlatform::Value.immutable(value)
      freeze
    end

    def match?(context)
      actual = TemplateResolver.lookup(context, path)
      case operator
      when "equals" then actual == value
      when "not_equals" then actual != value
      when "includes" then Array(actual).include?(value)
      when "exists" then !actual.nil?
      else false
      end
    end

    def to_h
      { path: path, operator: operator, value: value }
    end
  end

  class WorkflowDefinition
    VERSION_PATTERN = /\A\d+\.\d+\.\d+\z/.freeze
    FORBIDDEN_CAPABILITIES = %w[kg.proposals.submit].freeze

    attr_reader :id, :version, :trigger_types, :conditions, :steps, :outputs,
                :description

    def initialize(id:, version:, on:, steps:, conditions: [], outputs: {}, description: nil)
      @id = identifier(id)
      @version = version.to_s
      raise InvalidWorkflow, "workflow version must be semantic" unless @version.match?(VERSION_PATTERN)
      @trigger_types = Array(on).map(&:to_s).uniq.sort.freeze
      raise InvalidWorkflow, "workflow needs at least one trigger" if @trigger_types.empty?
      unless @trigger_types.all? { |type| type.match?(Event::TYPE_PATTERN) }
        raise InvalidWorkflow, "workflow has an invalid trigger type"
      end
      @conditions = Array(conditions).map do |item|
        item.is_a?(WorkflowCondition) ? item : WorkflowCondition.new(**symbolize(item))
      end.freeze
      @steps = Array(steps).map do |item|
        item.is_a?(WorkflowStep) ? item : WorkflowStep.new(**symbolize(item))
      end.freeze
      raise InvalidWorkflow, "workflow needs at least one step" if @steps.empty?
      raise InvalidWorkflow, "workflow step ids must be unique" unless @steps.map(&:id).uniq.length == @steps.length
      forbidden = @steps.map(&:capability_id) & FORBIDDEN_CAPABILITIES
      unless forbidden.empty?
        raise InvalidWorkflow, "workflow cannot automate approval-gated Engine execution: #{forbidden.join(', ')}"
      end
      validate_dependencies!
      raise InvalidWorkflow, "workflow outputs must be an object" unless outputs.is_a?(Hash)
      @outputs = AgentPlatform::Value.immutable(outputs)
      @description = description && description.to_s.freeze
      freeze
    end

    def matches?(event)
      trigger_types.include?(event.type) && conditions.all? do |condition|
        condition.match?("event" => event.to_h.transform_keys(&:to_s))
      end
    end

    def ordered_steps
      complete = []
      remaining = steps.sort_by(&:id)
      until remaining.empty?
        ready = remaining.select { |step| (step.depends_on - complete.map(&:id)).empty? }
        raise InvalidWorkflow, "workflow dependency cycle detected" if ready.empty?

        ready.sort_by(&:id).each do |step|
          complete << step
          remaining.delete(step)
        end
      end
      complete.freeze
    end

    def digest
      Stable.digest(to_h)
    end

    def to_h
      {
        id: id, version: version, description: description, on: trigger_types,
        conditions: conditions.map(&:to_h), steps: steps.map(&:to_h), outputs: outputs
      }.reject { |_key, value| value.nil? }
    end

    private

    def identifier(value)
      candidate = AgentPlatform::Value.required_string(value, "workflow id", maximum: 100)
      raise InvalidWorkflow, "invalid workflow id" unless candidate.match?(/\A[a-z][a-z0-9_-]*\z/)

      candidate
    end

    def validate_dependencies!
      ids = steps.map(&:id)
      steps.each do |step|
        missing = step.depends_on - ids
        raise InvalidWorkflow, "step #{step.id} has unknown dependencies: #{missing.join(', ')}" unless missing.empty?
        raise InvalidWorkflow, "step #{step.id} cannot depend on itself" if step.depends_on.include?(step.id)
      end
      ordered_steps
    end

    def symbolize(value)
      raise InvalidWorkflow, "workflow component must be an object" unless value.is_a?(Hash)

      value.transform_keys(&:to_sym)
    end
  end

  class WorkflowRegistry
    def initialize(definitions = [])
      @definitions = {}
      Array(definitions).each { |definition| register(definition) }
    end

    def register(definition)
      raise InvalidWorkflow, "expected WorkflowDefinition" unless definition.is_a?(WorkflowDefinition)
      key = [definition.id, definition.version]
      raise InvalidWorkflow, "duplicate workflow #{key.join('@')}" if @definitions.key?(key)

      @definitions[key] = definition
      self
    end

    def fetch(id, version: nil)
      matches = @definitions.values.select { |definition| definition.id == id.to_s }
      matches.select! { |definition| definition.version == version.to_s } if version
      matches.max_by { |definition| definition.version.split(".").map(&:to_i) } ||
        raise(WorkflowNotFound, "workflow not found: #{id}#{version ? "@#{version}" : ''}")
    end

    def list
      @definitions.values.sort_by { |definition| [definition.id, definition.version.split(".").map(&:to_i)] }.freeze
    end
  end

  class WorkflowLoader
    def load(paths)
      files = Array(paths).flat_map do |path|
        File.directory?(path.to_s) ? Dir[File.join(path.to_s, "**/*.{yml,yaml}")] : [path.to_s]
      end.uniq.sort.select { |path| File.file?(path) }
      raise InvalidWorkflow, "no workflow definitions found" if files.empty?

      files.flat_map { |path| load_file(path) }.freeze
    end

    private

    def load_file(path)
      payload = YAML.safe_load(File.read(path), aliases: false)
      raise InvalidWorkflow, "workflow file must contain an object" unless payload.is_a?(Hash)
      data = payload.transform_keys(&:to_s)
      raise InvalidWorkflow, "unsupported workflow schema" unless data.fetch("schema_version", 1) == 1
      Array(data.fetch("workflows")).map do |item|
        values = item.transform_keys(&:to_s)
        WorkflowDefinition.new(
          id: values.fetch("id"), version: values.fetch("version"),
          on: values.key?("on") ? values.fetch("on") : values.fetch("true"),
          description: values["description"], conditions: values.fetch("conditions", []),
          steps: values.fetch("steps"), outputs: values.fetch("outputs", {})
        )
      end
    rescue Psych::Exception => error
      raise InvalidWorkflow, "invalid workflow YAML #{path}: #{error.message}"
    rescue KeyError => error
      raise InvalidWorkflow, "workflow file #{path} is missing #{error.key}"
    end
  end

  class TriggerEngine
    def initialize(registry)
      @registry = registry
    end

    def workflows_for(event)
      target = event.payload["_workflow"]
      @registry.list.select do |definition|
        (!target || definition.id == target.to_s) && definition.matches?(event)
      end.sort_by { |definition| [definition.id, definition.version] }.freeze
    end
  end

  module TemplateResolver
    module_function

    def resolve(value, context)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = resolve(item, context) }
      when Array
        value.map { |item| resolve(item, context) }
      when String
        resolve_string(value, context)
      else value
      end
    end

    def lookup(context, expression)
      path = expression.to_s.sub(/\A\$/, "")
      path.split(".").reject(&:empty?).reduce(context) do |current, segment|
        return nil unless current.is_a?(Hash)

        current[segment] || current[segment.to_sym]
      end
    end

    def resolve_string(value, context)
      if value.start_with?("$") && !value.include?(" ")
        result = lookup(context, value)
        raise InvalidWorkflow, "template path not found: #{value}" if result.nil?
        return AgentPlatform::Value.mutable(result)
      end

      value.gsub(/\{\{([^}]+)\}\}/) do
        result = lookup(context, Regexp.last_match(1).strip)
        raise InvalidWorkflow, "template path not found: #{Regexp.last_match(1)}" if result.nil?

        result.is_a?(String) || result.is_a?(Numeric) ? result.to_s : Stable.json(result)
      end
    end
  end

  class PluginRegistrar
    def initialize(event_registry:, workflow_registry:, capability_registrar: nil)
      @event_registry = event_registry
      @workflow_registry = workflow_registry
      @capability_registrar = capability_registrar
    end

    def register_event(type, versions: [1])
      @event_registry.register(type, versions: versions)
      self
    end

    def register_workflow(definition)
      @workflow_registry.register(definition)
      self
    end

    def register_step(manifest:, handler:)
      raise PluginError, "capability registrar is unavailable" unless @capability_registrar

      @capability_registrar.register(manifest: manifest, handler: handler)
      self
    end
  end
end
