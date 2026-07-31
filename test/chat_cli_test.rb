# frozen_string_literal: true

require "json"
require "stringio"
require "tempfile"
require_relative "test_helper"

class ChatCLITest < Minitest::Test
  RUN_ID = "run_01KYW03MB8YQ7DV4THE9YQRK23"
  TIMESTAMP = "2026-07-30T12:34:56Z"
  PERSON_ID = "person_01K1D9VB96W7CS7F4M7K8Q2Z0A"

  def test_help_registers_chat_and_lists_supported_options
    with_schema_vault do |root|
      status, help, errors = run_cli(root, "chat", "--help")
      assert_equal 0, status, errors
      assert_empty errors
      assert_includes help, "Usage: kg chat"
      assert_includes help, "--conversation"
      assert_includes help, "--explain"

      status, commands, errors = run_cli(root, "--help")
      assert_equal 0, status, errors
      assert_empty errors
      assert_includes commands, "chat, observe"
    end
  end

  def test_observation_route_preserves_metadata_and_privacy_guarantees
    with_schema_vault do |root|
      message = "Ivan Petrov works at Microsoft."
      before = KnowledgeIntelligence::GraphSnapshot.load(vault_root: root).digest
      status, output, errors = run_cli(
        root, "chat",
        "--source", "telegram",
        "--conversation", "tg:123456",
        "--message-id", "98765",
        "--sender", "alex",
        "--timestamp", TIMESTAMP,
        "--text", message,
        "--json", "--explain"
      )

      assert_equal 0, status, errors
      assert_empty errors
      payload = JSON.parse(output)
      assert_equal "ok", payload.fetch("status")
      assert_equal "observe", payload.fetch("route")
      assert_equal "kg.observe", payload.dig("explain", "capability")
      observation = payload.fetch("result")
      proposal_id = observation.dig("proposals", 0, "id")
      proposal = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(proposal_id)
      source = proposal.fetch("source")
      assert_equal "chat", source.fetch("source_type")
      assert_equal "telegram", source.dig("metadata", "observation_source")
      assert_equal "tg:123456", source.dig("metadata", "conversation_id")
      assert_equal "98765", source.dig("metadata", "message_id")
      assert_equal "alex", source.fetch("author")
      assert_equal before, KnowledgeIntelligence::GraphSnapshot.load(vault_root: root).digest

      events = KnowledgeOrchestration::EventStore.new(vault_root: root).events
      refute_includes JSON.generate(events.map(&:to_h)), message
      artifacts = KnowledgeOrchestration::KnowledgeCache.new(vault_root: root).list
      refute_empty artifacts
      artifacts.each { |artifact| refute_includes JSON.generate(artifact.value), message }

      status, proposal_output, errors = run_cli(
        root, "chat", "--text", "Show status of #{proposal_id}.", "--json"
      )
      assert_equal 0, status, errors
      assert_empty errors
      proposal_response = JSON.parse(proposal_output)
      assert_equal "proposal", proposal_response.fetch("route")
      assert_equal proposal_id, proposal_response.dig("result", "proposal_id")
    end
  end

  def test_search_plan_proposal_and_clarification_routes
    with_schema_vault do |root|
      create_person(root)

      status, output, errors = run_cli(
        root, "chat", "--text", "Where does Ivan Petrov work?", "--json", "--explain"
      )
      assert_equal 0, status, errors
      assert_empty errors
      search = JSON.parse(output)
      assert_equal "search", search.fetch("route")
      assert_equal PERSON_ID, search.dig("result", "matches", 0, "id")
      assert_equal "kg.entities.search", search.dig("explain", "capability")

      status, output, errors = run_cli(
        root, "chat", "--text", "Create a plan for reconnecting with Ivan.", "--json"
      )
      assert_equal 0, status, errors
      assert_empty errors
      plan = JSON.parse(output)
      assert_equal "plan", plan.fetch("route")
      assert_equal false, plan.dig("result", "executable")

      status, output, errors = run_cli(
        root, "chat", "--text", "Show pending proposals.", "--json"
      )
      assert_equal 0, status, errors
      assert_empty errors
      proposal = JSON.parse(output)
      assert_equal "clarification_required", proposal.fetch("status")
      assert_equal "proposal", proposal.fetch("route")
      assert_includes proposal.dig("clarification", "question"), "proposal"

      status, output, errors = run_cli(root, "chat", "--text", "Ivan Petrov", "--json")
      assert_equal 0, status, errors
      assert_empty errors
      clarification = JSON.parse(output)
      assert_equal "clarification_required", clarification.fetch("status")
      assert_equal "clarification", clarification.fetch("route")
    end
  end

  def test_stdin_file_and_json_errors_emit_only_machine_readable_stdout
    with_schema_vault do |root|
      status, output, errors = run_cli(
        root, "chat", "--stdin", "--json", stdin: StringIO.new("Who is Ivan?")
      )
      assert_equal 0, status, errors
      assert_empty errors
      assert_equal "search", JSON.parse(output).fetch("route")

      Tempfile.create(["chat", ".txt"]) do |file|
        file.write("Ivan Petrov")
        file.flush
        status, output, errors = run_cli(root, "chat", "--file", file.path, "--json")
        assert_equal 0, status, errors
        assert_empty errors
        assert_equal "clarification", JSON.parse(output).fetch("route")
      end

      status, output, errors = run_cli(
        root, "chat", "--text", "one", "--stdin", "--json",
        stdin: StringIO.new("two")
      )
      assert_equal 2, status
      assert_empty errors
      assert_equal "invalid_chat", JSON.parse(output).dig("error", "code")
    end
  end

  private

  def create_person(root)
    KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID).execute(
      KnowledgeGraph::CreateEntity.new(
        entity_type: "person",
        attributes: {
          id: PERSON_ID, name: "Ivan Petrov", tier: "active",
          sensitivity: "normal", data_origin: "public"
        }
      )
    )
  end

  def run_cli(root, *arguments, stdin: StringIO.new)
    out = StringIO.new
    err = StringIO.new
    status = KnowledgeGraph::CLI.run(
      ["--vault", root, "--run-id", RUN_ID, *arguments],
      out: out, err: err, stdin: stdin
    )
    [status, out.string, err.string]
  end
end
