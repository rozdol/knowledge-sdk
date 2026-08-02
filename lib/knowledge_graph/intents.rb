# frozen_string_literal: true

module KnowledgeGraph
  class CreateEntity < Intent
    field :entity_type
    field :attributes, default: -> { {} }
    field :body, default: nil
    field :human_approved, default: false
  end

  class UpdateEntity < Intent
    field :entity_id
    field :changes
  end

  class RenameEntity < Intent
    field :entity_id
    field :new_name
  end

  class ArchiveEntity < Intent
    field :entity_id
  end

  class RestoreEntity < Intent
    field :entity_id
  end

  class MergeEntities < Intent
    field :primary_id
    field :secondary_id
    field :human_approved, default: false
  end

  class SplitEntity < Intent
    field :entity_id
    field :attributes
    field :body, default: nil
    field :human_approved, default: false
  end

  class AddRelationship < Intent
    field :source
    field :predicate
    field :target
    field :attributes, default: -> { {} }
  end

  class RemoveRelationship < Intent
    field :relationship_id
  end

  class ReplaceRelationship < Intent
    field :relationship_id
    field :source
    field :predicate
    field :target
    field :attributes, default: -> { {} }
  end

  class CreateMeeting < Intent
    field :attributes
    field :body, default: nil
  end

  class ImportTranscript < Intent
    field :interaction_id
    field :transcript
  end

  class AttachEvidence < Intent
    field :entity_id
    field :source_links, default: -> { [] }
    field :source_urls, default: -> { [] }
  end

  class RecordInteraction < Intent
    field :attributes
    field :body, default: nil
  end

  class RecordPromise < Intent
    field :attributes
    field :body, default: nil
  end

  class CompleteFollowUp < Intent
    field :follow_up_id
    field :completed_on, default: nil
  end

  class InsertDatasetRow < Intent
    field :dataset
    field :values
    field :source
    field :observation_id
    field :proposal_id, default: nil
    field :approval_id, default: nil
  end

  # Dataset Intents are canonical structured-row mutations. They deliberately
  # carry no graph entity attributes; handlers persist their values in SQLite.
  class DatasetIntent < Intent
    field :source
    field :observation_id
    field :proposal_id, default: nil
  end

  class ReplaceMedicationSchedule < DatasetIntent
    field :medication
    field :schedule
    field :effective_on
    field :dose, default: nil
    field :unit, default: nil
    field :schedule_details, default: nil
  end

  class InsertBloodPressureMeasurement < DatasetIntent
    field :observed_at
    field :systolic
    field :diastolic
    field :pulse, default: nil
  end

  class InsertWeightMeasurement < DatasetIntent
    field :observed_at
    field :weight_kg
  end

  class InsertBloodTestResult < DatasetIntent
    field :observed_at
    field :marker
    field :value
    field :unit, default: nil
  end

  class InsertBodyMeasurement < DatasetIntent
    field :observed_at
    field :measurement
    field :value
    field :unit
  end

  class InsertExpense < DatasetIntent
    field :occurred_on
    field :category
    field :amount
    field :currency
    field :merchant, default: nil
  end

  # Dataset lifecycle Intents keep registry and schema evolution on the same
  # approval/audit boundary as row mutations. The executable schema is data;
  # only the trusted Structured Dataset handler may interpret it.
  class DatasetLifecycleIntent < Intent
    field :source
    field :proposal_id, default: nil
  end

  class CreateDataset < DatasetLifecycleIntent
    field :dataset_id
    field :dataset
    field :schema
    field :owner_id, default: nil
  end

  class UpgradeDatasetSchema < DatasetLifecycleIntent
    field :dataset
    field :from_version
    field :schema
    field :added_columns
  end
end
