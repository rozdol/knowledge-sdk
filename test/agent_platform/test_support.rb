# frozen_string_literal: true

require_relative "../test_helper"

module AgentPlatformTestSupport
  RUN_ID = "run_01KYRPCAHVTXNJYXX9GZHS0HN9".freeze
  FIXED_TIME = Time.new(2026, 7, 30, 10, 0, 0, "+03:00").freeze
  PERSON_ID = "person_01K1D9VB96W7CS7F4M7K8Q2Z0A".freeze
  RESTRICTED_PERSON_ID = "person_01K1D9VB96W7CS7F4M7K8Q2Z0B".freeze
  ORGANIZATION_ID = "org_01K1DA3JCP8H3W7PX91NB6TR4P".freeze

  def build_gateway(root, permissions: ["*"], threaded_jobs: false, clock: nil)
    selected_clock = clock || -> { FIXED_TIME }
    gateway = AgentPlatform.build(
      vault_root: root, run_id: RUN_ID, actor_id: "agent:test",
      clock: selected_clock, threaded_jobs: threaded_jobs
    )
    agent = AgentPlatform::AgentIdentity.new(id: "agent:test", permissions: permissions)
    [gateway, agent]
  end

  def create_base_entities(root, restricted: false)
    engine = KnowledgeGraph::Engine.new(
      vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME }
    )
    engine.execute(KnowledgeGraph::CreateEntity.new(
      entity_type: "person", attributes: {
        id: PERSON_ID, name: "Ada Example", aliases: ["Ada"], tier: "active",
        sensitivity: "private", data_origin: "public", is_self: true
      }
    ))
    engine.execute(KnowledgeGraph::CreateEntity.new(
      entity_type: "organization", attributes: {
        id: ORGANIZATION_ID, name: "ExampleCo", aliases: [], org_kind: "company"
      }
    ))
    if restricted
      engine.execute(KnowledgeGraph::CreateEntity.new(
        entity_type: "person", attributes: {
          id: RESTRICTED_PERSON_ID, name: "Secret Example", aliases: [], tier: "active",
          sensitivity: "restricted", data_origin: "third_party"
        }
      ))
    end
    engine
  end

  def contract(gateway, agent, capability_id)
    gateway.discover(agent: agent).find { |item| item.fetch("capability_id") == capability_id } ||
      raise("missing capability #{capability_id}")
  end

  def invoke(gateway, agent, capability_id, arguments = {}, session_id: nil)
    selected = contract(gateway, agent, capability_id)
    request = gateway.issue_request(
      invocation_token: selected.fetch("invocation_token"), arguments: arguments,
      session_id: session_id
    )
    gateway.execute(request: request, agent: agent)
  end
end

class Minitest::Test
  include AgentPlatformTestSupport
end
