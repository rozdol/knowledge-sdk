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
    field :evidence_id, default: nil
    field :source_uri, default: nil
    field :source_filename, default: nil
    field :source_page, default: nil
    field :source_span, default: nil
  end

  # Dataset Intents are canonical structured-row mutations. They deliberately
  # carry no graph entity attributes; handlers persist their values in SQLite.
  class DatasetIntent < Intent
    field :source
    field :observation_id
    field :proposal_id, default: nil
  end

  class CreateMedicationSchedule < DatasetIntent
    field :schedule_id
    field :medication
    field :schedule_json
    field :effective_from
    field :effective_until, default: nil
    field :dose, default: nil
    field :unit, default: nil
    field :route, default: nil
    field :active, default: true
    field :reason, default: nil
    field :prescribing_provider, default: nil
    field :notes, default: nil
  end

  # The legacy schedule/effective_on fields remain readable so approved Phase
  # 13 proposals and direct Ruby callers can be replayed. New proposals use
  # schedule_json and effective_from exclusively.
  class ReplaceMedicationSchedule < DatasetIntent
    field :medication
    field :schedule_id, default: nil
    field :replacement_schedule_id, default: nil
    field :replace_all, default: false
    field :schedule_json, default: nil
    field :effective_from, default: nil
    field :effective_until, default: nil
    field :dose, default: nil
    field :unit, default: nil
    field :route, default: nil
    field :reason, default: nil
    field :prescribing_provider, default: nil
    field :notes, default: nil
    field :schedule, default: nil
    field :effective_on, default: nil
    field :schedule_details, default: nil
  end

  class PauseMedicationSchedule < DatasetIntent
    field :schedule_id, default: nil
    field :medication, default: nil
    field :paused_on
    field :replacement_schedule_id
    field :reason, default: nil
  end

  class ResumeMedicationSchedule < DatasetIntent
    field :schedule_id, default: nil
    field :medication, default: nil
    field :resumed_on
    field :replacement_schedule_id
    field :effective_until, default: nil
    field :reason, default: nil
  end

  class StopMedication < DatasetIntent
    field :medication
    field :stopped_on
    field :reason, default: nil
  end

  class ModifyMedicationDose < DatasetIntent
    field :schedule_id, default: nil
    field :medication, default: nil
    field :replacement_schedule_id
    field :dose
    field :effective_from
    field :unit, default: nil
    field :reason, default: nil
  end

  class ModifyMedicationSchedule < DatasetIntent
    field :schedule_id, default: nil
    field :medication, default: nil
    field :replacement_schedule_id
    field :schedule_json
    field :effective_from
    field :reason, default: nil
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
    field :template_id, default: nil
    field :template_version, default: nil
    field :template_digest, default: nil
  end

  class UpgradeDatasetSchema < DatasetLifecycleIntent
    field :dataset
    field :from_version
    field :schema
    field :added_columns
    field :migration_id, default: nil
  end

  # Capture content and identity are immutable. Separate lifecycle Intents
  # change only review/link/promotion/archive metadata through the Engine.
  class CreateCapture < Intent
    field :capture_id, default: nil
    field :kind
    field :title
    field :body
    field :captured_at, default: nil
    field :created_by, default: "agent"
    field :importance, default: "normal"
    field :topics, default: -> { [] }
    field :tags, default: -> { [] }
    field :language, default: "und"
    field :evidence, default: -> { [] }
    field :source, default: "unknown"
    field :sensitivity, default: "private"
    # Bookmark-only immutable metadata. These fields stay optional so the
    # Phase 16 Capture API and ordinary schema-v1 Captures remain compatible.
    field :url, default: nil
    field :canonical_url, default: nil
    field :domain, default: nil
    field :resource_type, default: nil
    field :user_note, default: nil
    field :collections, default: -> { [] }
    field :author_name, default: nil
    field :published_at, default: nil
    field :description, default: nil
    field :content_excerpt, default: nil
    field :content_hash, default: nil
    field :fetch_status, default: nil
    field :fetched_at, default: nil
    field :page_language, default: nil
    field :reading_status, default: nil
  end

  class ReviewCapture < Intent
    field :capture_id
  end

  class LinkCapture < Intent
    field :capture_id
    field :related_entities, default: -> { [] }
    field :related_projects, default: -> { [] }
    field :related_contacts, default: -> { [] }
  end

  class PromoteCapture < Intent
    field :capture_id
    field :target_kind
    field :target_ids
  end

  class ArchiveCapture < Intent
    field :capture_id
  end
end
