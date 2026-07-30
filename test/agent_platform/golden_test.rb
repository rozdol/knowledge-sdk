# frozen_string_literal: true

require_relative "test_support"

class AgentPlatformGoldenTest < Minitest::Test
  def test_agent_platform_golden_scenarios
    with_schema_vault do |root|
      create_base_entities(root)
      gateway, agent = build_gateway(
        root,
        permissions: %w[graph:read intelligence:read proposal:create proposal:read proposal:submit]
      )

      search = invoke(gateway, agent, "kg.entities.search", { "query" => "Ada Example" })
      assert_equal PERSON_ID, search.payload.fetch("matches").first.fetch("id")

      briefing = invoke(gateway, agent, "kg.intelligence.briefing", {
        "entity_ids" => [PERSON_ID], "as_of" => "2026-07-30"
      })
      assert briefing.success?
      assert_includes briefing.payload.fetch("summary"), "selected entities"

      before = KnowledgeIntelligence::GraphSnapshot.load(vault_root: root).digest
      extraction = invoke(gateway, agent, "kg.extraction.extract_source", {
        "source_type" => "transcript", "content" => "Ada Example works at ExampleCo",
        "language" => "en", "captured_at" => "2026-07-30T10:00:00+03:00",
        "sensitivity" => "private"
      })
      after = KnowledgeIntelligence::GraphSnapshot.load(vault_root: root).digest
      assert extraction.success?
      assert_equal false, extraction.payload.fetch("executable")
      assert_equal before, after, "proposal creation must not mutate canonical graph"

      proposal_id = extraction.payload.fetch("proposal_id")
      validation = invoke(gateway, agent, "kg.proposals.validate", { "proposal_id" => proposal_id })
      assert_equal "valid", validation.payload.fetch("status")

      unapproved = invoke(gateway, agent, "kg.proposals.submit", {
        "proposal_id" => proposal_id, "dry_run" => true
      })
      assert_equal "approval_required", unapproved.status

      unknown_request = AgentPlatform::AgentRequest.new(
        id: "request_unknown", timestamp: FIXED_TIME, capability_token: "cap_unknown",
        arguments: {}, trace_id: "trace_unknown"
      )
      unknown = gateway.execute(request: unknown_request, agent: agent)
      assert_equal "CapabilityNotFound", unknown.errors.first.fetch("code")
    end
  end

  def test_approved_proposal_is_still_submitted_only_through_existing_engine_pipeline
    with_schema_vault do |root|
      create_base_entities(root)
      gateway, agent = build_gateway(
        root, permissions: %w[proposal:create proposal:read proposal:submit]
      )
      extraction = invoke(gateway, agent, "kg.extraction.extract_source", {
        "source_type" => "text", "content" => "Ada Example works at ExampleCo",
        "language" => "en", "captured_at" => "2026-07-30T10:00:00+03:00"
      })
      store = KnowledgeExtraction::ProposalStore.new(vault_root: root, clock: -> { FIXED_TIME })
      proposal = AgentPlatform::Value.mutable(store.load(extraction.payload.fetch("proposal_id")))
      proposal_id = KnowledgeIntelligence::Stable.id("proposal", "phase-7-approved-synthetic-fixture")
      proposal["proposal_id"] = proposal_id
      proposal["status"] = "awaiting_approval"
      proposal.fetch("planned_intents").each do |item|
        item["blocked_reasons"] = []
        item["planning_confidence"] = 1.0
        params = item.fetch("intent").fetch("params")
        params["source"] = PERSON_ID
        params["target"] = ORGANIZATION_ID
      end
      store.save(proposal)
      KnowledgeExtraction::ProposalValidator.new.validate!(proposal)
      approvable = proposal.fetch("planned_intents").map { |item| item.fetch("planned_intent_id") }
      refute_empty approvable
      store.approve(proposal_id: proposal_id, intent_ids: approvable, actor_id: "human:test")

      response = invoke(gateway, agent, "kg.proposals.submit", {
        "proposal_id" => proposal_id, "dry_run" => true
      })
      assert response.success?
      assert_equal "planned", response.payload.fetch("status")
      assert response.payload.fetch("results").all? { |item| item.fetch("status") == "dry_run" }
      refute KnowledgeGraph::GraphReader.new(vault_root: root).relationship_exists?(
        source_id: PERSON_ID, predicate: "works_for", target_id: ORGANIZATION_ID
      )
    end
  end
end
