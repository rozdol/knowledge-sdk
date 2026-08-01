# frozen_string_literal: true

require "json"
require "stringio"
require "tempfile"
require_relative "test_support"

class KnowledgeExtractionSubmissionCLITest < Minitest::Test
  RUN_ID = "run_01KYQF65HF914CR66153C5P12X"

  def test_approved_proposal_executes_only_through_engine_and_resubmits_idempotently
    with_schema_vault do |root|
      document = extraction_document
      store = KnowledgeExtraction::ProposalStore.new(vault_root: root, clock: -> { FIXED_TIME })
      proposal = pipeline_for(root, raw_relationship(document), store: store).process(document, persist: true)
      intent_ids = proposal.planned_intents.map(&:planned_intent_id)
      store.approve(proposal_id: proposal.proposal_id, intent_ids: intent_ids, actor_id: "human:test")
      engine = KnowledgeGraph::Engine.new(
        vault_root: root, run_id: RUN_ID, actor_id: "human:test", clock: -> { FIXED_TIME }
      )
      submitter = KnowledgeExtraction::ProposalSubmitter.new(engine: engine, store: store, clock: -> { FIXED_TIME })
      first = submitter.submit(proposal.proposal_id)
      assert_equal "executed", first.fetch("status")
      assert first.fetch("results").all? { |result| result.fetch("status") == "executed" }
      assert_equal 3, first.fetch("results").length

      reader = KnowledgeGraph::GraphReader.new(vault_root: root)
      alice = reader.search("Alice Carter").first.fetch(:entity)
      northstar = reader.search("Northstar").first.fetch(:entity)
      assert reader.relationship_exists?(source_id: alice.id, predicate: "works_for", target_id: northstar.id)
      assert_equal "OK: 3 canonical notes, 19 entity schemas, 39 predicates\n", validator_output(root)

      second = submitter.submit(proposal.proposal_id)
      assert_equal "executed", second.fetch("status")
      assert second.fetch("results").all? { |result| result.fetch("replayed") }
      assert_equal 3, KnowledgeGraph::GraphReader.new(vault_root: root).search("Alice Carter").length +
                      KnowledgeGraph::GraphReader.new(vault_root: root).search("Northstar").length + 1
      assert File.file?(File.join(root, ".knowledge/runtime/audit.jsonl"))
      assert_operator Dir.glob(File.join(root, ".knowledge/runtime/receipts/*.json")).length, :>=, 3
    end
  end

  def test_unapproved_and_blocked_intents_never_execute
    with_schema_vault do |root|
      document = extraction_document
      store = KnowledgeExtraction::ProposalStore.new(vault_root: root)
      proposal = pipeline_for(root, raw_relationship(document), store: store).process(document, persist: true)
      result = KnowledgeExtraction::ProposalSubmitter.new(
        engine: KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID), store: store
      ).submit(proposal.proposal_id)
      assert_equal "partially_rejected", result.fetch("status")
      assert result.fetch("results").all? { |item| item.fetch("status") == "blocked" }
      assert result.fetch("results").all? { |item| item.fetch("reasons").any? { |reason| reason.include?("approval") } }
      assert_empty KnowledgeGraph::GraphReader.new(vault_root: root).search("Alice Carter")
    end
  end

  def test_concept_creation_requires_exact_approval_receipt
    with_schema_vault do |root|
      document = extraction_document("Alice Carter is interested in Sailing.")
      payload = raw_relationship(
        document, predicate: "interested_in", object: "Sailing", object_type: "interest"
      )
      store = KnowledgeExtraction::ProposalStore.new(vault_root: root, clock: -> { FIXED_TIME })
      proposal = pipeline_for(root, payload, store: store).process(document, persist: true)
      unblocked = proposal.planned_intents.reject(&:blocked?).map(&:planned_intent_id)
      store.approve(proposal_id: proposal.proposal_id, intent_ids: unblocked, actor_id: "human:test")
      result = KnowledgeExtraction::ProposalSubmitter.new(
        engine: KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME }),
        store: store
      ).submit(proposal.proposal_id)
      assert_equal "executed", result.fetch("status")
      interest = KnowledgeGraph::GraphReader.new(vault_root: root).search("Sailing", entity_type: "interest")
      assert_equal 1, interest.length
    end
  end

  def test_dependency_failure_stops_later_groups_without_rolling_back_prior_safe_group
    with_schema_vault do |root|
      document = extraction_document
      store = KnowledgeExtraction::ProposalStore.new(vault_root: root)
      proposal = pipeline_for(root, raw_relationship(document), store: store).process(document, persist: true)
      intent_ids = proposal.planned_intents.map(&:planned_intent_id)
      store.approve(proposal_id: proposal.proposal_id, intent_ids: intent_ids, actor_id: "human:test")
      real_engine = KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME })
      failing_engine = Object.new
      failing_engine.define_singleton_method(:execute) do |intent|
        raise KnowledgeGraph::RelationshipConflict, "synthetic relationship failure" if intent.is_a?(KnowledgeGraph::AddRelationship)

        real_engine.execute(intent)
      end
      result = KnowledgeExtraction::ProposalSubmitter.new(engine: failing_engine, store: store).submit(proposal.proposal_id)
      assert_equal "partially_rejected", result.fetch("status")
      assert_equal 2, result.fetch("results").count { |item| item.fetch("status") == "executed" }
      assert_equal 1, result.fetch("results").count { |item| item.fetch("status") == "failed" }
      reader = KnowledgeGraph::GraphReader.new(vault_root: root)
      assert_equal 1, reader.search("Alice Carter").length
      assert_equal 1, reader.search("Northstar").length
      refute reader.relationship_exists?(
        source_id: reader.search("Alice Carter").first.fetch(:entity).id,
        predicate: "works_for",
        target_id: reader.search("Northstar").first.fetch(:entity).id
      )
    end
  end

  def test_cli_dry_run_extract_and_proposal_lifecycle
    with_schema_vault do |root|
      Tempfile.create(["source", ".txt"]) do |file|
        file.write("Alice Carter works at Northstar.")
        file.flush
        status, output, errors = run_cli(root, "extract", "text", "--file", file.path, "--captured-at", FIXED_TIME.iso8601, "--dry-run")
        assert_equal 0, status, errors
        assert_includes output, "Facts: 1"
        assert_includes output, "Intents: 3"
        refute_includes output, "Artifact:"

        status, persisted, errors = run_cli(root, "extract", "text", "--file", file.path, "--captured-at", FIXED_TIME.iso8601)
        assert_equal 0, status, errors
        proposal_id = persisted[/Proposal (proposal_[0-9A-HJKMNP-TV-Z]{26})/, 1]
        refute_nil proposal_id
        assert_includes persisted, "Artifact:"

        status, validation, errors = run_cli(root, "proposal", "validate", proposal_id)
        assert_equal 0, status, errors
        assert_equal "valid", JSON.parse(validation).fetch("status")

        status, markdown, errors = run_cli(root, "proposal", "show", proposal_id)
        assert_equal 0, status, errors
        assert_includes markdown, "# Knowledge Extraction Proposal"

        status, approval, errors = run_cli(root, "--actor-id", "human:test", "proposal", "approve", proposal_id, "--all")
        assert_equal 0, status, errors
        assert_equal proposal_id, JSON.parse(approval).fetch("proposal_id")

        status, submission, errors = run_cli(root, "proposal", "submit", proposal_id, "--dry-run")
        assert_equal 0, status, errors
        assert_equal "planned", JSON.parse(submission).fetch("status")
      end
    end
  end

  private

  def run_cli(root, *arguments)
    out = StringIO.new
    err = StringIO.new
    status = KnowledgeGraph::CLI.run(
      ["--vault", root, "--run-id", RUN_ID, *arguments], out: out, err: err
    )
    [status, out.string, err.string]
  end

  def validator_output(root)
    validator = KnowledgeSDK.root.join("validators/personal_crm/validate_vault.rb").to_s
    IO.popen({ "VAULT_ROOT" => root }, [RbConfig.ruby, validator], &:read)
  end
end
