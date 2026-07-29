# frozen_string_literal: true

require_relative "test_support"

class KnowledgeExtractionResolutionPlanningTest < Minitest::Test
  RUN_ID = "run_01KYQF65HF914CR66153C5P12X"
  ALICE = "person_01K1D9VB96W7CS7F4M7K8Q2Z0A"
  ALEX_ONE = "person_01K1D9VB96W7CS7F4M7K8Q2Z0B"
  ALEX_TWO = "person_01K1D9VB96W7CS7F4M7K8Q2Z0C"

  def test_email_resolves_but_name_only_remains_ambiguous
    with_schema_vault do |root|
      create_people(root)
      reader = KnowledgeGraph::GraphReader.new(vault_root: root)
      resolver = KnowledgeExtraction::ConservativeEntityResolver.new(
        graph_reader: reader, configuration: extraction_configuration(root)
      )
      email = KnowledgeExtraction::EntityMention.new(
        entity_type: "person", display_name: "Alice Carter", email: "alice@example.test"
      )
      same_name = KnowledgeExtraction::EntityMention.new(entity_type: "person", display_name: "Alex Lee")
      decisions = resolver.resolve([email, same_name])
      assert_equal "resolved", decisions[0].outcome
      assert_equal ALICE, decisions[0].selected_entity_id
      assert_in_delta 0.99, decisions[0].selected_candidate.score, 0.001
      assert_equal "ambiguous", decisions[1].outcome
      assert_equal 2, decisions[1].candidates.length
      assert_nil decisions[1].selected_entity_id
    end
  end

  def test_conflicting_strong_identity_is_never_selected
    with_schema_vault do |root|
      create_people(root)
      resolver = KnowledgeExtraction::ConservativeEntityResolver.new(
        graph_reader: KnowledgeGraph::GraphReader.new(vault_root: root),
        configuration: extraction_configuration(root)
      )
      mention = KnowledgeExtraction::EntityMention.new(
        entity_type: "person", display_name: "Alice Carter", email: "different@example.test"
      )
      decision = resolver.resolve([mention]).first
      assert_equal "conflict", decision.outcome
      assert_nil decision.selected_entity_id
      assert_includes decision.candidates.first.conflicts, "email differs from candidate"
    end
  end

  def test_new_entities_produce_existing_intents_with_explicit_dependencies
    with_schema_vault do |root|
      document = extraction_document
      proposal = pipeline_for(root, raw_relationship(document)).process(document)
      types = proposal.planned_intents.map { |item| item.intent.intent_type }
      assert_equal %w[CreateEntity CreateEntity AddRelationship], types
      relationship = proposal.planned_intents.last
      assert_equal 2, relationship.dependencies.length
      assert relationship.dependencies.all? do |dependency|
        proposal.planned_intents.map(&:planned_intent_id).include?(dependency)
      end
      assert_empty relationship.blocked_reasons
      assert_equal "human_review", relationship.approval_requirement
      assert_equal proposal.source.source_id, relationship.provenance.fetch(:source_id)
      assert_equal relationship.fact_ids, relationship.provenance.fetch(:fact_ids)
      assert_operator relationship.evidence_ids.length, :>, 0
    end
  end

  def test_negated_planned_and_low_confidence_facts_produce_no_intents
    with_schema_vault do |root|
      %w[negated planned uncertain].each do |status|
        document = extraction_document
        payload = raw_relationship(document, status: status, confidence: status == "planned" ? 0.55 : 0.95)
        proposal = pipeline_for(root, payload).process(document)
        assert_empty proposal.planned_intents, status
        assert proposal.rejected_items.any? { |item| item.reason.include?(status) }
      end
      document = extraction_document
      proposal = pipeline_for(root, raw_relationship(document, confidence: 0.20)).process(document)
      assert_empty proposal.planned_intents
      assert proposal.rejected_items.any? { |item| item.reason.include?("confidence") }
    end
  end

  def test_historical_relationship_without_end_date_is_blocked
    with_schema_vault do |root|
      document = extraction_document
      proposal = pipeline_for(root, raw_relationship(document, status: "historical", confidence: 0.95)).process(document)
      relationship = proposal.planned_intents.find { |item| item.intent.is_a?(KnowledgeGraph::AddRelationship) }
      assert relationship.blocked?
      assert_includes relationship.blocked_reasons, "historical relationship needs an explicit valid_to date"
      assert_equal "resolution_required", proposal.status
    end
  end

  def test_new_ontology_concept_uses_engine_approval_gate
    with_schema_vault do |root|
      document = extraction_document("Alice Carter is interested in Sailing.")
      payload = raw_relationship(
        document, predicate: "interested_in", object: "Sailing", object_type: "interest"
      )
      proposal = pipeline_for(root, payload).process(document)
      interest = proposal.planned_intents.find do |item|
        item.intent.is_a?(KnowledgeGraph::CreateEntity) && item.intent.entity_type == "interest"
      end
      refute interest.intent.human_approved
      assert_equal "explicit_engine_approval", interest.approval_requirement
      assert_equal "medium", interest.risk
      refute proposal.planned_intents.any? { |item| item.intent.is_a?(KnowledgeGraph::MergeEntities) }
    end
  end

  def test_unsupported_predicate_is_rejected_but_evidence_is_preserved
    with_schema_vault do |root|
      document = extraction_document("Alice Carter controls Northstar.")
      payload = raw_relationship(document, predicate: "controls_everything")
      proposal = pipeline_for(root, payload).process(document)
      assert_equal 1, proposal.facts.length
      refute proposal.planned_intents.any? { |item| item.intent.is_a?(KnowledgeGraph::AddRelationship) }
      assert proposal.rejected_items.any? { |item| item.reason.include?("unsupported relationship predicate") }
      assert_equal document.content, proposal.facts.first.evidence.first.excerpt
    end
  end

  def test_planning_is_deterministic_for_fixed_source_and_provider_output
    with_schema_vault do |root|
      document = extraction_document
      first = pipeline_for(root, raw_relationship(document)).process(document)
      second = pipeline_for(root, raw_relationship(document)).process(document)
      assert_equal first.proposal_id, second.proposal_id
      assert_equal first.canonical_json, second.canonical_json
      assert_equal first.planned_intents.map(&:idempotency_key), second.planned_intents.map(&:idempotency_key)
    end
  end

  private

  def create_people(root)
    engine = KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME })
    [
      [ALICE, "Alice Carter", "alice@example.test"],
      [ALEX_ONE, "Alex Lee", "alex.one@example.test"],
      [ALEX_TWO, "Alex Lee", "alex.two@example.test"]
    ].each do |id, name, email|
      engine.execute(
        KnowledgeGraph::CreateEntity.new(
          entity_type: "person",
          attributes: {
            id: id, name: name, aliases: [], emails: [email], tier: "active",
            sensitivity: "private", data_origin: "public"
          }
        )
      )
    end
  end
end
