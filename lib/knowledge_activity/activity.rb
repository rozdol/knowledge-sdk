# frozen_string_literal: true

module KnowledgeActivity
  class Activity
    ATTRIBUTES = %i[
      id type summary created_at source actor proposal events affected_objects
      undo_available restore_available privacy audit
    ].freeze

    attr_reader(*ATTRIBUTES)

    def initialize(**attributes)
      missing = ATTRIBUTES - attributes.keys
      raise ArgumentError, "activity attributes missing: #{missing.join(', ')}" unless missing.empty?

      attributes.each do |key, value|
        instance_variable_set("@#{key}", AgentPlatform::Value.immutable(value))
      end
      freeze
    end

    def to_h
      {
        id: id, type: type, summary: summary, created_at: created_at,
        source: source, actor: actor, proposal: proposal, events: events,
        affected_objects: affected_objects, undo_available: undo_available,
        restore_available: restore_available, privacy: privacy
      }.reject { |_key, value| value.nil? }
    end
  end
end
