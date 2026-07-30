# frozen_string_literal: true

require_relative "test_support"

class AgentPlatformGatewayTest < Minitest::Test
  def test_discovery_and_typed_token_execution_do_not_leak_storage
    with_schema_vault do |root|
      create_base_entities(root)
      gateway, agent = build_gateway(root, permissions: %w[graph:read graph:private])

      discovered = gateway.discover(agent: agent)
      assert_equal %w[kg.companies.search kg.entities.get kg.entities.search kg.graph.relationship_path kg.projects.search],
                   discovered.map { |item| item.fetch("capability_id") }

      response = invoke(gateway, agent, "kg.entities.search", { "query" => "Ada Example" })
      assert response.success?
      assert_equal PERSON_ID, response.payload.fetch("matches").first.fetch("id")
      serialized = JSON.generate(response.to_h)
      refute_includes serialized, "relative_path"
      refute_includes serialized, "People/Ada Example.md"
      refute_includes serialized, "vault_root"
    end
  end

  def test_arbitrary_string_dispatch_and_invalid_arguments_are_rejected
    with_schema_vault do |root|
      gateway, agent = build_gateway(root, permissions: ["graph:read"])
      request = AgentPlatform::AgentRequest.new(
        id: "request_test", timestamp: FIXED_TIME,
        capability_token: "kg.entities.search", arguments: { "query" => "Ada" },
        trace_id: "trace_test"
      )
      response = gateway.execute(request: request, agent: agent)
      assert_equal "CapabilityNotFound", response.errors.first.fetch("code")

      selected = contract(gateway, agent, "kg.entities.search")
      invalid = gateway.issue_request(
        invocation_token: selected.fetch("invocation_token"),
        arguments: { "query" => "Ada", "implementation" => "internal" }
      )
      response = gateway.execute(request: invalid, agent: agent)
      assert_equal "invalid_request", response.status
      assert_equal "InvalidArguments", response.errors.first.fetch("code")
    end
  end

  def test_policy_filters_discovery_and_restricted_entities
    with_schema_vault do |root|
      create_base_entities(root, restricted: true)
      gateway, agent = build_gateway(root, permissions: ["graph:read"])

      refute gateway.discover(agent: agent).any? { |item| item.fetch("capability_id") == "kg.proposals.submit" }
      response = invoke(gateway, agent, "kg.entities.search", { "query" => "Secret Example" })
      assert_empty response.payload.fetch("matches")
      response = invoke(gateway, agent, "kg.entities.get", { "entity_id" => RESTRICTED_PERSON_ID })
      assert_equal "denied", response.status

      privileged = AgentPlatform::AgentIdentity.new(
        id: "agent:restricted", permissions: %w[graph:read graph:restricted]
      )
      response = invoke(gateway, privileged, "kg.entities.get", { "entity_id" => RESTRICTED_PERSON_ID })
      assert response.success?
    end
  end

  def test_reasoning_response_contains_explanation_evidence_confidence_and_graph_path
    with_schema_vault do |root|
      create_base_entities(root)
      gateway, agent = build_gateway(root, permissions: ["intelligence:read"])
      response = invoke(
        gateway, agent, "kg.intelligence.timeline", { "as_of" => "2026-07-30" }
      )

      assert response.success?
      refute_empty response.why
      refute_nil response.confidence
      assert_kind_of Array, response.evidence
      assert_kind_of Array, response.graph_path
    end
  end

  def test_relationship_path_hides_restricted_edges
    with_schema_vault do |root|
      engine = create_base_entities(root)
      engine.execute(KnowledgeGraph::CreateEntity.new(
        entity_type: "person", attributes: {
          id: RESTRICTED_PERSON_ID, name: "Grace Example", aliases: [], tier: "active",
          sensitivity: "private", data_origin: "public"
        }
      ))
      engine.link(
        source: PERSON_ID, predicate: "knows", target: RESTRICTED_PERSON_ID,
        sensitivity: "restricted", data_origin: "third_party"
      )
      gateway, agent = build_gateway(root, permissions: ["graph:read"])
      response = invoke(gateway, agent, "kg.graph.relationship_path", {
        "source_id" => PERSON_ID, "target_id" => RESTRICTED_PERSON_ID, "mode" => "social"
      })

      assert response.success?
      assert_nil response.payload.fetch("graph_path")
      assert_empty response.evidence
    end
  end

  def test_intelligence_outputs_do_not_leak_restricted_records
    with_schema_vault do |root|
      create_base_entities(root, restricted: true)
      gateway, agent = build_gateway(root, permissions: ["intelligence:read"])
      response = invoke(gateway, agent, "kg.intelligence.analyze", {
        "analyzers" => ["knowledge_gap", "network"], "as_of" => "2026-07-30"
      })
      serialized = JSON.generate(response.to_h)

      assert response.success?
      refute_includes serialized, RESTRICTED_PERSON_ID
      refute_includes serialized, "Secret Example"
    end
  end

  def test_telemetry_contains_metadata_but_not_arguments_or_graph_data
    with_schema_vault do |root|
      create_base_entities(root)
      gateway, agent = build_gateway(root, permissions: ["graph:read"])
      response = invoke(gateway, agent, "kg.entities.search", { "query" => "Ada Example" })
      trace = gateway.explain_trace(trace_id: response.trace_id, agent: agent)
      serialized = JSON.generate(trace)

      assert_includes serialized, "kg.entities.search"
      refute_includes serialized, "Ada Example"
      refute_includes serialized, PERSON_ID
    end
  end
end
