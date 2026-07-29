# frozen_string_literal: true

require_relative "test_helper"

class IntentTest < Minitest::Test
  def test_all_public_intents_are_immutable
    intents = [
      KnowledgeGraph::CreateEntity.new(entity_type: "person"),
      KnowledgeGraph::UpdateEntity.new(entity_id: "person_1", changes: { name: "Ada" }),
      KnowledgeGraph::RenameEntity.new(entity_id: "person_1", new_name: "Ada"),
      KnowledgeGraph::ArchiveEntity.new(entity_id: "person_1"),
      KnowledgeGraph::RestoreEntity.new(entity_id: "person_1"),
      KnowledgeGraph::MergeEntities.new(primary_id: "person_1", secondary_id: "person_2"),
      KnowledgeGraph::SplitEntity.new(entity_id: "person_1", attributes: { name: "Other" }),
      KnowledgeGraph::AddRelationship.new(source: "person_1", predicate: "knows", target: "person_2"),
      KnowledgeGraph::RemoveRelationship.new(relationship_id: "relationship_1"),
      KnowledgeGraph::ReplaceRelationship.new(
        relationship_id: "relationship_1", source: "person_1", predicate: "knows", target: "person_2"
      ),
      KnowledgeGraph::CreateMeeting.new(attributes: { name: "Review" }),
      KnowledgeGraph::ImportTranscript.new(interaction_id: "interaction_1", transcript: "Hello"),
      KnowledgeGraph::AttachEvidence.new(entity_id: "person_1"),
      KnowledgeGraph::RecordInteraction.new(attributes: { name: "Call" }),
      KnowledgeGraph::RecordPromise.new(attributes: { action: "Reply" }),
      KnowledgeGraph::CompleteFollowUp.new(follow_up_id: "followup_1")
    ]

    intents.each { |intent| assert_predicate intent, :frozen? }
  end

  def test_deep_freezes_input_without_sharing_mutable_values
    changes = { aliases: ["Countess"] }
    intent = KnowledgeGraph::UpdateEntity.new(entity_id: "person_1", changes: changes)
    changes[:aliases] << "Programmer"

    assert_equal ["Countess"], intent.changes[:aliases]
    assert_raises(FrozenError) { intent.changes[:aliases] << "Mathematician" }
  end

  def test_rejects_missing_and_unknown_fields
    assert_raises(KnowledgeGraph::InvalidIntent) { KnowledgeGraph::RenameEntity.new(entity_id: "person_1") }
    assert_raises(KnowledgeGraph::InvalidIntent) do
      KnowledgeGraph::ArchiveEntity.new(entity_id: "person_1", mystery: true)
    end
  end

  def test_serializes_with_stable_intent_type
    intent = KnowledgeGraph::ArchiveEntity.new(entity_id: "person_1", intent_id: "request-7")

    assert_equal "ArchiveEntity", intent.to_h[:intent_type]
    assert_equal "request-7", intent.to_h[:intent_id]
  end
end
