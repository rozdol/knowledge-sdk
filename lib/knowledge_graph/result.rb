# frozen_string_literal: true

module KnowledgeGraph
  class Result
    attr_reader :intent_type, :entity_ids, :changed_paths, :value, :replayed,
                :duration_ms, :audit_id

    def initialize(intent_type:, entity_ids: [], changed_paths: [], value: nil,
                   replayed: false, duration_ms: nil, audit_id: nil)
      @intent_type = intent_type.to_s.freeze
      @entity_ids = entity_ids.map { |item| item.to_s.dup.freeze }.freeze
      @changed_paths = changed_paths.map { |item| item.to_s.dup.freeze }.freeze
      @value = value
      @replayed = !!replayed
      @duration_ms = duration_ms
      @audit_id = audit_id&.to_s&.freeze
      freeze
    end

    def success?
      true
    end
  end
end
