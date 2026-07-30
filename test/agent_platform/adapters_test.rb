# frozen_string_literal: true

require "stringio"
require_relative "test_support"

class AgentPlatformAdaptersTest < Minitest::Test
  def test_hermes_mcp_and_rest_derive_contracts_from_same_manifest
    with_schema_vault do |root|
      create_base_entities(root)
      gateway, agent = build_gateway(root, permissions: ["graph:read"])
      hermes = AgentPlatform::Adapters::Hermes.new(gateway)
      mcp = AgentPlatform::Adapters::MCP.new(gateway)
      rest = AgentPlatform::Adapters::REST.new(gateway)

      contract = hermes.capabilities(agent: agent).find { |item| item.fetch("capability_id") == "kg.entities.search" }
      tool = mcp.tools(agent: agent).find { |item| item.fetch(:_meta).fetch(:capability_id) == "kg.entities.search" }
      assert_equal contract.fetch("manifest_digest"), tool.fetch(:_meta).fetch(:manifest_digest)
      assert_equal contract.fetch("input_schema"), tool.fetch(:inputSchema)

      hermes_result = hermes.execute(
        invocation_token: contract.fetch("invocation_token"), arguments: { "query" => "Ada Example" }, agent: agent
      )
      mcp_result = mcp.call_tool(name: tool.fetch(:name), arguments: { "query" => "Ada Example" }, agent: agent)
      rest_result = rest.execute(
        body: { invocation_token: contract.fetch("invocation_token"), arguments: { query: "Ada Example" } },
        agent: agent
      )

      assert_equal "succeeded", hermes_result.fetch(:status)
      refute mcp_result.fetch(:isError)
      assert_equal 200, rest_result.fetch(:status)
      assert_equal PERSON_ID, rest_result.fetch(:body).fetch(:payload).fetch("matches").first.fetch("id")
    end
  end

  def test_mcp_rejects_tool_not_present_in_policy_filtered_discovery
    with_schema_vault do |root|
      gateway, agent = build_gateway(root, permissions: ["graph:read"])
      adapter = AgentPlatform::Adapters::MCP.new(gateway)

      assert_raises(AgentPlatform::CapabilityNotFound) do
        adapter.call_tool(name: "kg_proposals_submit__v1", arguments: {}, agent: agent)
      end
    end
  end

  def test_gateway_cli_lists_and_executes_manifest_capabilities
    with_schema_vault do |root|
      create_base_entities(root)
      out = StringIO.new
      err = StringIO.new
      status = KnowledgeGraph::CLI.run(
        ["--vault", root, "--run-id", RUN_ID, "gateway", "execute", "kg.entities.search", '{"query":"Ada Example"}'],
        out: out, err: err
      )

      assert_equal 0, status
      assert_empty err.string
      payload = JSON.parse(out.string)
      assert_equal "succeeded", payload.fetch("status")
      assert_equal PERSON_ID, payload.fetch("payload").fetch("matches").first.fetch("id")
    end
  end
end
