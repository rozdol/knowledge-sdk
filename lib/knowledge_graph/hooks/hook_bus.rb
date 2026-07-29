# frozen_string_literal: true

module KnowledgeGraph
  class HookBus
    EVENTS = %i[
      before_execute after_execute before_commit after_commit before_rollback after_rollback
    ].freeze

    def initialize
      @subscribers = EVENTS.to_h { |event| [event, []] }
    end

    def subscribe(event, callable = nil, &block)
      event = event.to_sym
      raise ArgumentError, "unknown lifecycle hook #{event}" unless EVENTS.include?(event)

      subscriber = callable || block
      raise ArgumentError, "hook must respond to call" unless subscriber&.respond_to?(:call)

      @subscribers.fetch(event) << subscriber
      self
    end

    def emit(event, context)
      @subscribers.fetch(event).each { |subscriber| subscriber.call(context) }
    end
  end
end
