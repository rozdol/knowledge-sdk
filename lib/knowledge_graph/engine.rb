# frozen_string_literal: true

require "pathname"

module KnowledgeGraph
  class Engine
    attr_reader :vault_root

    def initialize(vault_root:, handlers: {})
      @vault_root = Pathname.new(vault_root).expand_path.freeze
      @handlers = {}
      handlers.each { |intent_class, handler| register(intent_class, handler) }
    end

    def register(intent_class, handler = nil, &block)
      callable = handler || block
      raise ArgumentError, "handler must respond to call" unless callable&.respond_to?(:call)
      raise ArgumentError, "handler key must be an Intent class" unless intent_class <= Intent

      @handlers[intent_class] = callable
      self
    end

    def execute(intent)
      raise InvalidIntent, "execute expects a KnowledgeGraph::Intent" unless intent.is_a?(Intent)

      handler = @handlers[intent.class]
      raise UnsupportedIntent, "no handler registered for #{intent.intent_type}" unless handler

      value = handler.call(intent)
      return value if value.is_a?(Result)

      Result.new(intent_type: intent.intent_type, value: value)
    end
  end
end
