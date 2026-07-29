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
end
