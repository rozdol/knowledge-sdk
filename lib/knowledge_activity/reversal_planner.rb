# frozen_string_literal: true

require "set"

module KnowledgeActivity
  class ReversalPlanner
    CREATION_INTENTS = %w[CreateEntity CreateMeeting RecordInteraction RecordPromise].freeze
    RELATIONSHIP_FIELDS = KnowledgeGraph::RelationshipManager::OPTIONAL_FIELDS

    def initialize(vault_root:, audits:)
      @vault_root = File.expand_path(vault_root.to_s)
      @audits = audits
      @registry = KnowledgeGraph::SchemaRegistry.new(vault_root: @vault_root)
      @repository = KnowledgeGraph::Repository.new(vault_root: @vault_root, registry: @registry)
      @relationship_registry = KnowledgeGraph::RelationshipRegistry.new(vault_root: @vault_root)
    end

    def available?(activity, operation:)
      !intents_for(activity, operation: operation).empty?
    rescue KnowledgeGraph::Error, KeyError, TypeError
      false
    end

    def intents_for(activity, operation:)
      intents = operation.to_s == "restore" ? restore_intents(activity) : undo_intents(activity)
      Array(intents).compact.map do |payload|
        normalized = AgentPlatform::Value.mutable(payload)
        KnowledgeGraph::IntentFactory.build(normalized)
        normalized
      end
    rescue KnowledgeGraph::Error, KeyError, TypeError => error
      raise ReversalUnavailable, "#{operation} is unavailable for #{activity.id}: #{error.message}"
    end

    private

    def undo_intents(activity)
      type, params = intent(activity)
      entity_id = activity.audit.fetch("entity_ids").first
      case type
      when *CREATION_INTENTS
        ensure_entity_state!(entity_id, "active")
        one("ArchiveEntity", "entity_id" => required(entity_id, "created object"))
      when "UpdateEntity"
        ensure_current_changes!(params.fetch("entity_id"), params.fetch("changes"))
        changes = previous_changes(activity, params.fetch("entity_id"), params.fetch("changes"))
        one("UpdateEntity", "entity_id" => params.fetch("entity_id"), "changes" => changes)
      when "RenameEntity"
        ensure_current_value!(params.fetch("entity_id"), "name", params.fetch("new_name"))
        one("RenameEntity", "entity_id" => params.fetch("entity_id"),
            "new_name" => previous_name(activity, params.fetch("entity_id")))
      when "ArchiveEntity"
        ensure_entity_state!(params.fetch("entity_id"), "archived")
        one("RestoreEntity", "entity_id" => params.fetch("entity_id"))
      when "RestoreEntity"
        ensure_entity_state!(params.fetch("entity_id"), "active")
        one("ArchiveEntity", "entity_id" => params.fetch("entity_id"))
      when "AddRelationship"
        ensure_relationship_state!(entity_id, "asserted")
        one("RemoveRelationship", "relationship_id" => required(entity_id, "relationship"))
      when "RemoveRelationship"
        ensure_relationship_state!(params.fetch("relationship_id"), "retracted")
        ensure_no_asserted_duplicate!(params.fetch("relationship_id"))
        [relationship_add(params.fetch("relationship_id"))]
      when "ReplaceRelationship"
        reverse_replacement(activity, params)
      else
        raise ReversalUnavailable, "#{type} has no lossless reverse Intent"
      end
    end

    def restore_intents(activity)
      type, params = intent(activity)
      entity_id = activity.audit.fetch("entity_ids").first
      case type
      when *CREATION_INTENTS
        ensure_entity_state!(entity_id, "archived")
        one("RestoreEntity", "entity_id" => required(entity_id, "created object"))
      when "UpdateEntity"
        previous = previous_changes(activity, params.fetch("entity_id"), params.fetch("changes"))
        ensure_current_changes!(params.fetch("entity_id"), previous)
        [{ "type" => type, "params" => AgentPlatform::Value.mutable(params) }]
      when "RenameEntity"
        ensure_current_value!(params.fetch("entity_id"), "name", previous_name(activity, params.fetch("entity_id")))
        [{ "type" => type, "params" => AgentPlatform::Value.mutable(params) }]
      when "ArchiveEntity"
        ensure_entity_state!(params.fetch("entity_id"), "active")
        [{ "type" => type, "params" => AgentPlatform::Value.mutable(params) }]
      when "RestoreEntity"
        ensure_entity_state!(params.fetch("entity_id"), "archived")
        [{ "type" => type, "params" => AgentPlatform::Value.mutable(params) }]
      when "AddRelationship"
        ensure_relationship_state!(entity_id, "retracted")
        ensure_no_asserted_duplicate!(entity_id)
        [{ "type" => type, "params" => AgentPlatform::Value.mutable(params) }]
      else
        raise ReversalUnavailable, "#{type} cannot be restored losslessly"
      end
    end

    def reverse_replacement(activity, params)
      old_id = params.fetch("relationship_id")
      new_id = activity.audit.fetch("entity_ids").find { |id| id != old_id }
      raise ReversalUnavailable, "replacement result does not identify the new relationship" unless new_id
      ensure_relationship_state!(old_id, "retracted")
      ensure_relationship_state!(new_id, "asserted")

      [
        { "type" => "RemoveRelationship", "params" => { "relationship_id" => new_id } },
        relationship_add(old_id)
      ]
    end

    def relationship_add(relationship_id)
      record = @repository.find(relationship_id)
      raise ReversalUnavailable, "#{relationship_id} is not a relationship" unless record.type == "relationship"

      data = record.data
      definition = @relationship_registry.fetch(data.fetch("predicate"))
      allowed = RELATIONSHIP_FIELDS | Set.new(definition.allowed_fields)
      attributes = data.each_with_object({}) do |(key, value), result|
        result[key] = value if allowed.include?(key)
      end
      {
        "type" => "AddRelationship",
        "params" => {
          "source" => data.fetch("subject_id"), "predicate" => data.fetch("predicate"),
          "target" => data.fetch("object_id"), "attributes" => attributes
        }
      }
    end

    def previous_changes(activity, entity_id, changes)
      state = entity_state_before(activity.audit.fetch("id"), entity_id)
      changes.each_with_object({}) do |(key, _value), result|
        string_key = key.to_s
        unless state.key?(string_key)
          raise ReversalUnavailable, "the previous value of #{string_key} is not present in replay history"
        end
        result[string_key] = state.fetch(string_key)
      end
    end

    def previous_name(activity, entity_id)
      state = entity_state_before(activity.audit.fetch("id"), entity_id)
      required(state["name"], "previous name")
    end

    def ensure_entity_state!(entity_id, expected)
      record = @repository.find(required(entity_id, "affected object"))
      actual = record.data["record_status"]
      return if actual == expected

      raise ReversalUnavailable, "the object is #{actual}, not #{expected}; a later activity changed it"
    end

    def ensure_relationship_state!(relationship_id, expected)
      record = @repository.find(required(relationship_id, "relationship"))
      raise ReversalUnavailable, "#{relationship_id} is not a relationship" unless record.type == "relationship"
      actual = record.data["relationship_status"]
      return if actual == expected

      raise ReversalUnavailable, "the relationship is #{actual}, not #{expected}; a later activity changed it"
    end

    def ensure_current_changes!(entity_id, changes)
      stringify(changes).each do |key, value|
        ensure_current_value!(entity_id, key, value)
      end
    end

    def ensure_current_value!(entity_id, key, expected)
      record = @repository.find(entity_id)
      actual = record.data[key.to_s]
      return if actual == expected

      raise ReversalUnavailable, "#{key} no longer has the value recorded by this activity"
    end

    def ensure_no_asserted_duplicate!(relationship_id)
      record = @repository.find(relationship_id)
      duplicate = nil
      @repository.each_record do |candidate|
        next unless candidate.type == "relationship" && candidate.id != record.id
        data = candidate.data
        if data["relationship_status"] == "asserted" &&
           data["subject_id"] == record.data["subject_id"] &&
           data["predicate"] == record.data["predicate"] &&
           data["object_id"] == record.data["object_id"]
          duplicate = candidate
          break
        end
      end
      return unless duplicate

      raise ReversalUnavailable, "the relationship was already restored by a later activity"
    end

    def entity_state_before(audit_id, entity_id)
      state = {}
      @audits.each do |audit|
        break if audit.fetch("id") == audit_id
        next unless audit.fetch("result") == "success"
        next unless audit.fetch("entity_ids", []).include?(entity_id)

        type, params = audit_intent(audit)
        case type
        when "CreateEntity"
          state.merge!(stringify(params.fetch("attributes", {})))
        when "CreateMeeting", "RecordInteraction", "RecordPromise"
          state.merge!(stringify(params.fetch("attributes", {})))
        when "UpdateEntity"
          state.merge!(stringify(params.fetch("changes", {})))
        when "RenameEntity"
          state["name"] = params.fetch("new_name")
        when "ArchiveEntity"
          state["record_status"] = "archived"
        when "RestoreEntity"
          state["record_status"] = "active"
        end
      end
      state
    end

    def intent(activity)
      audit_intent(activity.audit)
    end

    def audit_intent(audit)
      payload = audit.fetch("intent")
      [payload.fetch("type"), stringify(payload.fetch("params"))]
    end

    def one(type, params)
      [{ "type" => type, "params" => params }]
    end

    def required(value, label)
      raise ReversalUnavailable, "#{label} is unavailable" if value.nil? || value.to_s.empty?

      value
    end

    def stringify(value)
      value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
    end
  end
end
