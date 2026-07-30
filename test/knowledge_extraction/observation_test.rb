# frozen_string_literal: true

require "json"
require "stringio"
require "tempfile"
require_relative "test_support"

class KnowledgeExtractionObservationTest < Minitest::Test
  RUN_ID = "run_01KYSFAJF475TKFB6C5S9Z1N42"
  TIMESTAMP = "2026-07-30T12:34:56Z"
  EVENT_TYPES = %w[
    ObservationReceived ObservationParsed ExtractionCompleted ProposalCreated
    PolicyValidated ObservationCompleted
  ].freeze

  def test_observation_envelope_preserves_message_identity_across_revisions
    first = KnowledgeExtraction::ObservationEnvelope.new(
      source: "telegram", conversation: "tg:123456", message_id: "98765",
      sender: "alex", timestamp: TIMESTAMP, text: "Ivan works at Microsoft."
    )
    revised = KnowledgeExtraction::ObservationEnvelope.new(
      source: "telegram", conversation: "tg:123456", message_id: "98765",
      sender: "alex", timestamp: TIMESTAMP, text: "Ivan Petrov works at Microsoft."
    )
    separate = KnowledgeExtraction::ObservationEnvelope.new(
      source: "telegram", conversation: "tg:123456", message_id: "98766",
      sender: "alex", timestamp: TIMESTAMP, text: "Ivan Petrov works at Microsoft."
    )

    assert_equal first.observation_id, revised.observation_id
    refute_equal first.content_hash, revised.content_hash
    refute_equal revised.observation_id, separate.observation_id
    assert_equal "chat", first.source_type
    refute first.event_payload.key?("text")
  end

  def test_cli_json_runs_gateway_policy_events_and_cache_without_graph_mutation
    with_schema_vault do |root|
      before = KnowledgeIntelligence::GraphSnapshot.load(vault_root: root).digest
      status, output, errors = run_cli(
        root, "observe",
        "--source", "telegram",
        "--conversation", "tg:123456",
        "--message-id", "98765",
        "--sender", "alex",
        "--timestamp", TIMESTAMP,
        "--text", "Ivan Petrov works at Microsoft.",
        "--json", "--explain"
      )
      after = KnowledgeIntelligence::GraphSnapshot.load(vault_root: root).digest

      assert_equal 0, status, errors
      assert_empty errors
      assert_equal before, after
      payload = JSON.parse(output)
      assert AgentPlatform::SchemaValidator.new.validate!(
        KnowledgeExtraction::ObservationResult::JSON_SCHEMA, payload
      )
      assert_equal "ok", payload.fetch("status")
      assert_match(/\Aobservation_[0-9A-HJKMNP-TV-Z]{26}\z/, payload.fetch("observation_id"))
      assert_equal EVENT_TYPES, payload.fetch("events")
      assert_equal 2, payload.dig("summary", "entities_detected")
      assert_equal 1, payload.dig("summary", "proposals_created")
      assert_equal true, payload.dig("summary", "approval_required")
      assert_equal "pending_approval", payload.dig("proposals", 0, "status")
      assert_equal %w[knowledge_extraction entity_resolution], payload.dig("cache", "artifacts_created")
      assert_includes payload.fetch("explain"), "Policy validation passed"
      refute_includes output, "Runtime/"

      proposal_id = payload.dig("proposals", 0, "id")
      proposal = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(proposal_id)
      source = proposal.fetch("source")
      assert_equal "chat", source.fetch("source_type")
      assert_equal payload.fetch("observation_id"), source.fetch("external_id")
      assert_equal "alex", source.fetch("author")
      assert_equal "telegram", source.dig("metadata", "observation_source")
      assert_equal "tg:123456", source.dig("metadata", "conversation_id")
      assert_equal "98765", source.dig("metadata", "message_id")
      assert_equal payload.fetch("observation_id"), source.dig("metadata", "observation_id")
      assert_equal Time.iso8601(TIMESTAMP), Time.iso8601(source.fetch("captured_at"))

      events = KnowledgeOrchestration::EventStore.new(vault_root: root).events
      assert_equal EVENT_TYPES, events.map(&:type)
      assert events.all? { |event| event.correlation_id == payload.fetch("observation_id") }
      event_data = JSON.generate(events.map(&:to_h))
      refute_includes event_data, "Ivan Petrov works at Microsoft."
      policy_event = events.find { |event| event.type == "PolicyValidated" }
      assert_equal true, policy_event.payload.fetch("approval_required")
      assert policy_event.payload.fetch("capabilities").all? { |item| item.fetch("allowed") }
      assert_equal %w[1.1.0 1.0.0], policy_event.payload.fetch("capabilities").map { |item| item.fetch("capability_version") }

      artifacts = KnowledgeOrchestration::KnowledgeCache.new(vault_root: root).list
      assert_equal %w[entity_resolution knowledge_extraction], artifacts.map(&:artifact_type).sort
      artifacts.each do |artifact|
        dependencies = artifact.dependencies
        assert_equal [payload.fetch("observation_id")], dependencies.observation_ids
        assert_equal 5, dependencies.event_ids.length
        assert_equal before, dependencies.snapshot_digest
        assert_equal "kg.extraction.extract_source", dependencies.capability_id
        assert_equal "1.1.0", dependencies.capability_version
        assert dependencies.to_h.key?(:entity_ids)
        refute_includes JSON.generate(artifact.value), "Ivan Petrov works at Microsoft."
      end
    end
  end

  def test_ambiguity_returns_structured_clarification_without_guessing
    with_schema_vault do |root|
      engine = KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID)
      john_ids = %w[john-alpha john-beta].map do |seed|
        id = KnowledgeExtraction::Support.stable_id("person", seed)
        engine.execute(KnowledgeGraph::CreateEntity.new(
          entity_type: "person",
          attributes: {
            id: id, name: seed.split("-").map(&:capitalize).join(" "), aliases: ["John"],
            tier: "active", sensitivity: "normal", data_origin: "public"
          }
        ))
        id
      end
      before = KnowledgeIntelligence::GraphSnapshot.load(vault_root: root).digest

      status, output, errors = run_cli(
        root, "observe", "--source", "telegram", "--conversation", "tg:ambiguous",
        "--message-id", "1", "--timestamp", TIMESTAMP,
        "--text", "John works at Acme.", "--json"
      )

      assert_equal 0, status, errors
      payload = JSON.parse(output)
      assert_equal "clarification_required", payload.fetch("status")
      assert_includes payload.fetch("question"), "John"
      assert_equal john_ids.sort, payload.fetch("options").map { |item| item.fetch("entity_id") }.sort
      assert_equal 2, payload.fetch("options").length
      assert_equal before, KnowledgeIntelligence::GraphSnapshot.load(vault_root: root).digest
      proposal = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(payload.dig("proposals", 0, "id"))
      john = proposal.fetch("resolution_decisions").find do |decision|
        decision.fetch("candidates").length == 2
      end
      assert_equal "ambiguous", john.fetch("outcome")
      assert_nil john["selected_entity_id"]
    end
  end

  def test_cli_supports_help_stdin_file_human_explain_and_structured_input_errors
    with_schema_vault do |root|
      status, help, errors = run_cli(root, "observe", "--help")
      assert_equal 0, status, errors
      assert_includes help, "--conversation"
      assert_includes help, "--message-id"
      assert_includes help, "--source-type"

      status, human, errors = run_cli(
        root, "observe", "--stdin", "--timestamp", TIMESTAMP, "--explain",
        stdin: StringIO.new("Ada Example works at ExampleCo.")
      )
      assert_equal 0, status, errors
      assert_includes human, "Observation accepted."
      assert_includes human, "✓ Extraction completed"
      assert_includes human, "No knowledge has been modified."

      Tempfile.create(["transcript", ".txt"]) do |file|
        file.write("Meeting transcript without structured facts.")
        file.flush
        status, output, errors = run_cli(
          root, "observe", "--file", file.path, "--source", "transcript",
          "--timestamp", TIMESTAMP, "--json"
        )
        assert_equal 0, status, errors
        payload = JSON.parse(output)
        proposal = KnowledgeExtraction::ProposalStore.new(vault_root: root).load(payload.dig("proposals", 0, "id"))
        assert_equal "transcript", proposal.dig("source", "source_type")
      end

      status, output, errors = run_cli(
        root, "observe", "--text", "one", "--stdin", "--json",
        stdin: StringIO.new("two")
      )
      assert_equal 2, status
      assert_empty errors
      assert_equal "invalid_observation", JSON.parse(output).dig("error", "code")

      status, output, = run_cli(
        root, "observe", "--text", "one", "--timestamp", "not-a-time", "--json"
      )
      assert_equal 2, status
      assert_equal "error", JSON.parse(output).fetch("status")
    end
  end

  def test_generic_large_and_multilingual_observations_remain_review_only
    with_schema_vault do |root|
      before = KnowledgeIntelligence::GraphSnapshot.load(vault_root: root).digest
      observations = [
        "I met Ivan today.",
        "John introduced me to Ivan.",
        "I read a new book.",
        "We agreed to meet next week.",
        "There are two Johns.",
        "Сегодня я встретил Ивана.",
        ("Conversation line without a graph assertion.\n" * 2_000)
      ]
      observations.each_with_index do |text, index|
        status, output, errors = run_cli(
          root, "observe", "--source", "hermes", "--conversation", "golden",
          "--message-id", index.to_s, "--timestamp", TIMESTAMP,
          "--text", text, "--json"
        )
        assert_equal 0, status, errors
        assert_includes %w[ok clarification_required], JSON.parse(output).fetch("status")
      end
      assert_equal before, KnowledgeIntelligence::GraphSnapshot.load(vault_root: root).digest
    end
  end

  private

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
