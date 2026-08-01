# frozen_string_literal: true

module KnowledgeGraph
  class IntentFactory
    INTENTS = [
      CreateEntity, UpdateEntity, RenameEntity, ArchiveEntity, RestoreEntity, MergeEntities, SplitEntity,
      AddRelationship, RemoveRelationship, ReplaceRelationship, CreateMeeting, ImportTranscript,
      AttachEvidence, RecordInteraction, RecordPromise, CompleteFollowUp, InsertDatasetRow
    ].to_h { |intent_class| [intent_class.name.split("::").last, intent_class] }.freeze

    def self.build(payload)
      payload = payload.transform_keys(&:to_s)
      type = payload["intent"] || payload["type"]
      params = payload["params"] || payload.reject { |key, _value| %w[intent type].include?(key) }
      intent_class = INTENTS[type.to_s]
      raise InvalidIntent, "unknown intent type #{type.inspect}" unless intent_class
      raise InvalidIntent, "intent params must be an object" unless params.is_a?(Hash)

      intent_class.new(**params.transform_keys(&:to_sym))
    end
  end
end
