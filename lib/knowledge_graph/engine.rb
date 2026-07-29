# frozen_string_literal: true

require "pathname"

module KnowledgeGraph
  class Engine
    attr_reader :vault_root, :hooks

    def initialize(vault_root:, handlers: {}, validator: nil, transaction_factory: nil)
      @vault_root = Pathname.new(vault_root).expand_path.freeze
      @dispatcher = Dispatcher.new
      @hooks = HookBus.new
      @executor = Executor.new(
        vault_root: @vault_root,
        dispatcher: @dispatcher,
        hooks: @hooks,
        validator: validator,
        transaction_factory: transaction_factory
      )
      handlers.each { |intent_class, handler| register(intent_class, handler) }
    end

    def register(intent_class, handler = nil, &block)
      callable = handler || block
      raise ArgumentError, "handler must respond to call" unless callable&.respond_to?(:call)
      raise ArgumentError, "handler key must be an Intent class" unless intent_class <= Intent

      @dispatcher.register(intent_class, callable)
      self
    end

    def on(event, callable = nil, &block)
      @hooks.subscribe(event, callable, &block)
      self
    end

    def execute(intent)
      raise InvalidIntent, "execute expects a KnowledgeGraph::Intent" unless intent.is_a?(Intent)

      @executor.execute(intent)
    end
  end
end
