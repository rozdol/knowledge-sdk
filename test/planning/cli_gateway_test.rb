# frozen_string_literal: true

require "stringio"
require_relative "test_support"

class PlanningCLIGatewayTest < Minitest::Test
  def test_cli_planning_is_read_only_and_exposes_comparison
    with_schema_vault do |root|
      before = markdown_hashes(root)
      out = StringIO.new
      err = StringIO.new
      status = KnowledgeGraph::CLI.run(
        ["--vault", root, "plan", "compare", '{"description":"Synthetic baseline","goal_type":"generic"}',
         "--as-of", "2026-07-30"],
        out: out, err: err, stdin: StringIO.new
      )

      assert_equal 0, status, err.string
      payload = JSON.parse(out.string)
      refute_nil payload.fetch("approved_plan_id")
      assert_equal false, payload.fetch("alternatives").empty?
      assert_equal before, markdown_hashes(root)
    end
  end

  def test_gateway_discovers_and_executes_policy_filtered_planning
    with_schema_vault do |root|
      gateway = AgentPlatform.build(
        vault_root: root, run_id: "run_01KYRXTMW66XWJ6WT6QVCREJ3G",
        actor_id: "planning-test", threaded_jobs: false,
        clock: -> { Time.utc(2026, 7, 30, 8, 0, 0) }
      )
      denied = AgentPlatform::AgentIdentity.new(id: "denied", permissions: ["graph:read"])
      refute gateway.discover(agent: denied).any? { |item| item.fetch("capability_id").start_with?("kg.planning.") }

      agent = AgentPlatform::AgentIdentity.new(id: "planner", permissions: ["planning:read"])
      contract = gateway.discover(agent: agent).find { |item| item.fetch("capability_id") == "kg.planning.plan" }
      request = gateway.issue_request(
        invocation_token: contract.fetch("invocation_token"),
        arguments: {
          "goal" => { "description" => "Synthetic baseline", "goal_type" => "generic" },
          "as_of" => "2026-07-30"
        }
      )
      response = gateway.execute(request: request, agent: agent)

      assert response.success?, response.errors.inspect
      assert_equal false, response.payload.fetch("executable")
      assert_equal "decision_approved", response.payload.dig("approved_plan", "decision_status")
      refute_includes JSON.generate(response.to_h), '"path"'
    end
  end

  def test_gateway_removes_entire_plans_with_restricted_targets
    with_schema_vault do |root|
      self_id = "person_01K1D9VB96W7CS7F4M7K8Q2Z0A"
      secret_id = "person_01K1D9VB96W7CS7F4M7K8Q2Z0B"
      engine = KnowledgeGraph::Engine.new(
        vault_root: root, run_id: "run_01KYRXTMW66XWJ6WT6QVCREJ3G",
        clock: -> { Time.utc(2026, 7, 30, 8, 0, 0) }
      )
      engine.execute(KnowledgeGraph::CreateEntity.new(
        entity_type: "person", attributes: {
          id: self_id, name: "Synthetic Owner", tier: "inner", is_self: true,
          sensitivity: "private", data_origin: "public"
        }
      ))
      engine.execute(KnowledgeGraph::CreateEntity.new(
        entity_type: "person", attributes: {
          id: secret_id, name: "Restricted Synthetic Target", tier: "active",
          sensitivity: "restricted", data_origin: "third_party"
        }
      ))
      engine.link(source: self_id, predicate: "knows", target: secret_id,
                  sensitivity: "restricted", data_origin: "third_party")
      gateway = AgentPlatform.build(
        vault_root: root, run_id: "run_01KYRXTMW66XWJ6WT6QVCREJ3G",
        actor_id: "planning-test", threaded_jobs: false,
        clock: -> { Time.utc(2026, 7, 30, 8, 0, 0) }
      )
      agent = AgentPlatform::AgentIdentity.new(id: "planner", permissions: ["planning:read"])
      contract = gateway.discover(agent: agent).find { |item| item.fetch("capability_id") == "kg.planning.plan" }
      request = gateway.issue_request(
        invocation_token: contract.fetch("invocation_token"),
        arguments: {
          "goal" => {
            "description" => "Reach a restricted synthetic target", "goal_type" => "network_expansion",
            "preferences" => { "target_ids" => [secret_id] }
          }, "as_of" => "2026-07-30"
        }
      )
      response = gateway.execute(request: request, agent: agent)
      serialized = JSON.generate(response.to_h)

      assert response.success?, response.errors.inspect
      assert_nil response.payload.fetch("approved_plan")
      assert_empty response.payload.fetch("ranked_plans")
      refute_includes serialized, secret_id
      refute_includes serialized, "Restricted Synthetic Target"
    end
  end

  private

  def markdown_hashes(root)
    Dir.glob(File.join(root, "**/*.md")).sort.to_h do |path|
      [path.sub("#{root}/", ""), Digest::SHA256.file(path).hexdigest]
    end
  end
end
