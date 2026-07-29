# frozen_string_literal: true

module KnowledgeGraph
  class Dispatcher
    def initialize
      @handlers = {}
    end

    def register(intent_class, handler)
      @handlers[intent_class] = handler
    end

    def dispatch(intent, context)
      handler = @handlers[intent.class]
      raise UnsupportedIntent, "no handler registered for #{intent.intent_type}" unless handler

      arity = handler.respond_to?(:arity) ? handler.arity : handler.method(:call).arity
      arity == 1 ? handler.call(intent) : handler.call(intent, context)
    end
  end
end
