# frozen_string_literal: true

require "stringio"
require_relative "test_support"

class KnowledgeExtractionPipelineProposalTest < Minitest::Test
  def test_source_to_proposal_contains_complete_traceability
    with_schema_vault do |root|
      document = extraction_document
      proposal = pipeline_for(root, raw_relationship(document)).process(document)
      assert_match(/\Aproposal_[0-9A-HJKMNP-TV-Z]{26}\z/, proposal.proposal_id)
      assert_equal document.source_id, proposal.source.source_id
      assert_equal 1, proposal.facts.length
      assert_equal 2, proposal.entity_mentions.length
      assert_equal 2, proposal.resolution_decisions.length
      assert_equal 3, proposal.planned_intents.length
      assert_equal "awaiting_approval", proposal.status
      assert_equal 3, proposal.required_approvals.fetch(:total)
      proposal.planned_intents.each do |planned|
        assert_equal document.source_id, planned.provenance.fetch(:source_id)
        refute_empty planned.fact_ids
        refute_empty planned.evidence_ids
        assert planned.provenance.key?(:pipeline_version)
        assert planned.provenance.key?(:prompt_version)
        assert planned.provenance.key?(:resolution_decisions)
        assert planned.provenance.key?(:approval_classification)
      end
      parsed = JSON.parse(proposal.canonical_json)
      refute parsed.fetch("source").key?("content")
      assert_equal document.content_hash, parsed.fetch("source").fetch("content_hash")
    end
  end

  def test_explicit_stages_are_independently_callable_and_serializable
    with_schema_vault do |root|
      document = extraction_document
      pipeline = pipeline_for(root, raw_relationship(document))
      normalized = pipeline.normalize(document)
      raw = pipeline.extract(normalized)
      facts = pipeline.validate_facts(raw)
      resolved = pipeline.resolve_entities(facts)
      planning = pipeline.plan_intents(resolved)
      assert_equal document.to_h, normalized.to_h
      assert JSON.generate(raw.to_h)
      assert JSON.generate(facts.to_h)
      assert JSON.generate(resolved.to_h)
      assert JSON.generate(planning.to_h)
      assert_equal 3, planning.planned_intents.length
    end
  end

  def test_proposal_store_classifies_duplicate_revision_and_separate_duplicate_content
    with_schema_vault do |root|
      store = KnowledgeExtraction::ProposalStore.new(vault_root: root, clock: -> { FIXED_TIME })
      first = extraction_document("Alice Carter works at Northstar.", external_id: "mail:1")
      first_proposal = pipeline_for(root, raw_relationship(first), store: store).process(first, persist: true)
      assert_equal "new", first_proposal.ingestion_state
      assert store.path_for(first_proposal.proposal_id).file?

      duplicate = pipeline_for(root, raw_relationship(first), store: store).process(first, persist: true)
      assert_equal "exact_duplicate", duplicate.ingestion_state
      assert_includes duplicate.warnings.join(" "), "not silently discarded"

      revision = extraction_document("Alice Carter works at Northstar. Edited.", external_id: "mail:1")
      revised = pipeline_for(root, raw_relationship(revision), store: store).process(revision, persist: true)
      assert_equal "revision", revised.ingestion_state

      separate = extraction_document("Alice Carter works at Northstar.", external_id: "mail:2")
      separate_proposal = pipeline_for(root, raw_relationship(separate), store: store).process(separate)
      assert_equal "exact_content_duplicate", separate_proposal.ingestion_state
    end
  end

  def test_proposal_store_is_immutable_and_validates_fingerprints
    with_schema_vault do |root|
      store = KnowledgeExtraction::ProposalStore.new(vault_root: root)
      document = extraction_document
      proposal = pipeline_for(root, raw_relationship(document), store: store).process(document, persist: true)
      stored = store.load(proposal.proposal_id)
      assert KnowledgeExtraction::ProposalValidator.new.validate!(stored)
      assert_equal proposal.proposal_id, stored.fetch("proposal_id")
      assert_equal store.proposal_fingerprint(stored), store.proposal_fingerprint(store.load(proposal.proposal_id))

      broken = Marshal.load(Marshal.dump(stored))
      broken.fetch("planned_intents").first["fact_ids"] = ["fact_missing"]
      assert_raises(KnowledgeExtraction::PlanningFailure) do
        KnowledgeExtraction::ProposalValidator.new.validate!(broken)
      end
    end
  end

  def test_markdown_and_concise_renderers_distinguish_evidence_and_graph_change
    with_schema_vault do |root|
      document = extraction_document
      proposal = pipeline_for(root, raw_relationship(document)).process(document)
      markdown = KnowledgeExtraction::MarkdownProposalRenderer.new.render(proposal)
      assert_includes markdown, "## Extracted facts"
      assert_includes markdown, "**statement**"
      assert_includes markdown, "## Proposed graph changes"
      assert_includes markdown, "awaiting_approval"
      concise = KnowledgeExtraction::ConciseProposalRenderer.new.render(proposal)
      assert_includes concise, "Ingestion: new"
      assert_includes concise, "Facts: 1"
      assert_includes concise, "Intents: 3"
      assert_includes concise, "approvals: 3"
    end
  end

  def test_stage_metrics_log_durations_without_making_proposal_nondeterministic
    with_schema_vault do |root|
      document = extraction_document
      io = StringIO.new
      reader = KnowledgeGraph::GraphReader.new(vault_root: root)
      configuration = extraction_configuration(root, provider_name: "fake")
      pipeline = KnowledgeExtraction::KnowledgeExtractionPipeline.new(
        graph_reader: reader,
        provider: KnowledgeExtraction::FakeExtractionProvider.new(raw_relationship(document)),
        configuration: configuration,
        logger: KnowledgeExtraction::StructuredLogger.new(io: io)
      )
      proposal = pipeline.process(document)
      refute proposal.metrics.keys.any? { |key| key.end_with?("duration_ms") }
      log = JSON.parse(io.string)
      assert log.keys.any? { |key| key.end_with?("duration_ms") }
      refute_includes io.string, document.content
      assert_equal document.source_id, log.fetch("source_id")
    end
  end

  def test_provider_failure_creates_no_proposal_artifact_or_graph_change
    with_schema_vault do |root|
      provider = Class.new do
        def extract(_document, _context)
          raise "network unavailable"
        end
      end.new
      store = KnowledgeExtraction::ProposalStore.new(vault_root: root)
      pipeline = KnowledgeExtraction::KnowledgeExtractionPipeline.new(
        graph_reader: KnowledgeGraph::GraphReader.new(vault_root: root),
        provider: provider, configuration: extraction_configuration(root), proposal_store: store
      )
      assert_raises(KnowledgeExtraction::ProviderFailure) do
        pipeline.process(extraction_document, persist: true)
      end
      refute store.path_for("proposal_00000000000000000000000000").file?
      assert_equal 0, KnowledgeGraph::GraphReader.new(vault_root: root).search("Alice Carter").length
    end
  end
end
