# frozen_string_literal: true

require_relative "test_helper"

class CapabilityHandlersTest < Minitest::Test
  PERSON_A = "person_01K1D9VB96W7CS7F4M7K8Q2Z0A"
  PERSON_B = "person_01K1D9VB96W7CS7F4M7K8Q2Z0B"
  INTERACTION_A = "interaction_01K1DCC8Q6V4R5T7S2NXB8K4QA"
  INTERACTION_B = "interaction_01K1DCC8Q6V4R5T7S2NXB8K4QB"
  COMMITMENT = "commitment_01K1DCC8Q6V4R5T7S2NXB8K4QC"
  RUN_ID = "run_01KYQADDKGCXF0H38JFT5EN0CV"

  class TypedIdGenerator
    def initialize
      @ids = {
        "interaction" => [INTERACTION_A, INTERACTION_B],
        "commitment" => [COMMITMENT]
      }
    end

    def generate(prefix)
      @ids.fetch(prefix).shift
    end
  end

  def test_meeting_interaction_and_promise_use_the_same_create_pipeline
    with_schema_vault do |root|
      fixed_time = Time.new(2026, 7, 29, 10, 0, 0, "+03:00")
      engine = KnowledgeGraph::Engine.new(
        vault_root: root,
        run_id: RUN_ID,
        clock: -> { fixed_time },
        id_generator: TypedIdGenerator.new
      )
      create_people(engine)
      repository = repository_for(root)
      links = [repository.find(PERSON_A).link, repository.find(PERSON_B).link]

      meeting = engine.execute(
        KnowledgeGraph::CreateMeeting.new(
          attributes: {
            name: "Design review", starts_at: "2026-07-29T11:00:00+03:00", participants: links,
            sensitivity: "private", data_origin: "given_by_subject"
          }
        )
      )
      call = engine.execute(
        KnowledgeGraph::RecordInteraction.new(
          attributes: {
            name: "Follow-up call", starts_at: "2026-07-30T12:00:00+03:00", participants: links,
            interaction_kind: "call", contact_weight: "substantive",
            sensitivity: "private", data_origin: "given_by_subject"
          }
        )
      )
      promise = engine.execute(
        KnowledgeGraph::RecordPromise.new(
          attributes: {
            name: "Send notes", action: "Send notes", promisor: links.first, promise_to: links.last,
            made_on: "2026-07-29", sensitivity: "private", data_origin: "given_by_subject"
          }
        )
      )

      assert_match(%r{Interactions/Meetings/2026-07-29 - Design review}, meeting.value.fetch(:relative_path))
      assert_match(%r{Interactions/Calls/2026-07-30 - Follow-up call}, call.value.fetch(:relative_path))
      promise_record = repository_for(root).find(promise.entity_ids.first)
      assert_equal "promise", promise_record.data["commitment_kind"]
      assert_equal "open", promise_record.data["commitment_status"]
    end
  end

  private

  def create_people(engine)
    [
      [PERSON_A, "Ada", true],
      [PERSON_B, "Grace", false]
    ].each do |id, name, is_self|
      attributes = {
        id: id, name: name, tier: "active", sensitivity: "private", data_origin: "public"
      }
      attributes[:is_self] = true if is_self
      engine.execute(KnowledgeGraph::CreateEntity.new(entity_type: "person", attributes: attributes))
    end
  end

  def repository_for(root)
    registry = KnowledgeGraph::SchemaRegistry.new(vault_root: root)
    KnowledgeGraph::Repository.new(vault_root: root, registry: registry)
  end
end
