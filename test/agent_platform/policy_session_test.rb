# frozen_string_literal: true

require_relative "test_support"

class AgentPlatformPolicySessionTest < Minitest::Test
  def test_sessions_are_immutable_bounded_owned_and_expiring
    now = FIXED_TIME
    clock = -> { now }
    store = AgentPlatform::SessionStore.new(clock: clock)
    memory = AgentPlatform::WorkingMemory.new(references: [
      { kind: "entity", reference_id: PERSON_ID, label: "Ada" }
    ])
    session = store.create(
      conversation_id: "conversation-1", agent_id: "agent:test", ttl_seconds: 60,
      selected_entity_ids: [PERSON_ID], working_memory: memory
    )
    updated = store.update(
      session.id, agent_id: "agent:test", language: "ru",
      working_memory: session.working_memory.add(kind: "organization", reference_id: ORGANIZATION_ID)
    )

    assert_equal "und", session.language
    assert_equal "ru", updated.language
    assert_equal 2, updated.version
    assert_equal 2, updated.working_memory.references.length
    assert_raises(AgentPlatform::PolicyDenied) { store.fetch(session.id, agent_id: "another-agent") }

    now += 61
    assert_raises(AgentPlatform::SessionExpired) { store.fetch(session.id, agent_id: "agent:test") }
  end

  def test_working_memory_rejects_copies_and_unbounded_values
    assert_raises(ArgumentError) do
      AgentPlatform::MemoryReference.new(kind: "entity", reference_id: "Ada Example")
    end
    assert_raises(ArgumentError) do
      AgentPlatform::WorkingMemory.new(
        limit: 1,
        references: [
          { kind: "entity", reference_id: PERSON_ID },
          { kind: "organization", reference_id: ORGANIZATION_ID }
        ]
      )
    end
  end

  def test_submit_policy_requires_exact_existing_approval
    with_schema_vault do |root|
      gateway, agent = build_gateway(root, permissions: ["proposal:submit"])
      selected = contract(gateway, agent, "kg.proposals.submit")
      request = gateway.issue_request(
        invocation_token: selected.fetch("invocation_token"),
        arguments: { "proposal_id" => "proposal_01K1D9VB96W7CS7F4M7K8Q2Z0A", "dry_run" => true }
      )
      response = gateway.execute(request: request, agent: agent)

      assert_equal "approval_required", response.status
      assert_equal "ApprovalRequired", response.errors.first.fetch("code")
    end
  end

  def test_read_only_environment_hides_proposal_and_graph_writes
    with_schema_vault do |root|
      gateway = AgentPlatform.build(
        vault_root: root, run_id: RUN_ID, environment: "read_only", threaded_jobs: false,
        clock: -> { FIXED_TIME }
      )
      agent = AgentPlatform::AgentIdentity.new(id: "agent:test", permissions: ["*"])
      ids = gateway.discover(agent: agent).map { |item| item.fetch("capability_id") }

      assert_includes ids, "kg.entities.search"
      refute_includes ids, "kg.extraction.extract_source"
      refute_includes ids, "kg.proposals.submit"
    end
  end
end
