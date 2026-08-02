# frozen_string_literal: true

module KnowledgeGraph
  class IntentFactory
    INTENTS = [
      CreateEntity, UpdateEntity, RenameEntity, ArchiveEntity, RestoreEntity, MergeEntities, SplitEntity,
      AddRelationship, RemoveRelationship, ReplaceRelationship, CreateMeeting, ImportTranscript,
      AttachEvidence, RecordInteraction, RecordPromise, CompleteFollowUp, InsertDatasetRow,
      ReplaceMedicationSchedule, InsertBloodPressureMeasurement, InsertWeightMeasurement,
      InsertBloodTestResult, InsertBodyMeasurement, InsertExpense,
      CreateDataset, UpgradeDatasetSchema
    ].to_h { |intent_class| [intent_class.name.split("::").last, intent_class] }.freeze

    class << self
      def register(intent_class)
        unless intent_class.is_a?(Class) && intent_class <= KnowledgeGraph::Intent
          raise InvalidIntent, "registered intent must inherit KnowledgeGraph::Intent"
        end
        name = intent_class.name.to_s.split("::").last
        raise InvalidIntent, "registered intent class must have a name" if name.empty?

        existing = registered_intents[name]
        if existing && existing != intent_class
          raise InvalidIntent, "intent type #{name} is already registered"
        end
        registered_intents[name] = intent_class
        intent_class
      end

      def registered_intents
        @registered_intents ||= INTENTS.dup
      end
    end

    def self.build(payload)
      payload = payload.transform_keys(&:to_s)
      type = payload["intent"] || payload["type"]
      params = payload["params"] || payload.reject { |key, _value| %w[intent type].include?(key) }
      intent_class = registered_intents[type.to_s]
      raise InvalidIntent, "unknown intent type #{type.inspect}" unless intent_class
      raise InvalidIntent, "intent params must be an object" unless params.is_a?(Hash)

      intent_class.new(**params.transform_keys(&:to_sym))
    end
  end
end
