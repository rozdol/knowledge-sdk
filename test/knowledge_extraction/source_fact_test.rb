# frozen_string_literal: true

require_relative "test_support"

class KnowledgeExtractionSourceFactTest < Minitest::Test
  def test_all_required_source_adapters_preserve_metadata
    KnowledgeExtraction::SourceDocument::TYPES.each do |type|
      document = KnowledgeExtraction::SourceAdapter.for(type).build(
        "Hello\r\nworld", language: "en", external_id: "external-1",
        metadata: { "custom" => { "nested" => true } }
      )
      assert_equal type, document.source_type
      assert_equal "Hello\nworld", document.content
      assert_equal({ "custom" => { "nested" => true } }, document.metadata)
      assert_match(/\Asource_[0-9A-HJKMNP-TV-Z]{26}\z/, document.source_id)
      assert_match(/\A[0-9a-f]{64}\z/, document.content_hash)
    end
  end

  def test_source_ids_and_hashes_are_stable_and_revisions_keep_external_identity
    first = extraction_document("alpha", external_id: "mail:1")
    replay = extraction_document("alpha", external_id: "mail:1")
    revision = extraction_document("alpha edited", external_id: "mail:1")
    assert_equal first.source_id, replay.source_id
    assert_equal first.content_hash, replay.content_hash
    assert_equal first.source_id, revision.source_id
    refute_equal first.content_hash, revision.content_hash
  end

  def test_normalizer_detects_english_russian_greek_and_mixed
    normalizer = KnowledgeExtraction::SourceNormalizer.new
    assert_equal "en", normalizer.normalize("A plain note", source_type: "text").language
    assert_equal "ru", normalizer.normalize("Привет", source_type: "text").language
    assert_equal "el", normalizer.normalize("Καλημέρα", source_type: "text").language
    assert_equal "mixed", normalizer.normalize("Привет John", source_type: "text").language
  end

  def test_source_size_and_type_are_closed
    config = KnowledgeExtraction::Configuration.new(source_size_limit: 5)
    normalizer = KnowledgeExtraction::SourceNormalizer.new(configuration: config)
    assert_raises(KnowledgeExtraction::NormalizationFailure) do
      normalizer.normalize("123456", source_type: "text")
    end
    assert_raises(KnowledgeExtraction::UnsupportedSource) do
      KnowledgeExtraction::SourceAdapter.for("browser")
    end
  end

  def test_content_hash_cannot_be_forged
    assert_raises(KnowledgeExtraction::NormalizationFailure) do
      KnowledgeExtraction::SourceDocument.new(
        source_type: "text", content: "hello", content_hash: "0" * 64
      )
    end
  end

  def test_evidence_validates_exact_offsets_and_source
    document = extraction_document("Alice met Bob.")
    span = KnowledgeExtraction::EvidenceSpan.new(
      source_id: document.source_id, start_offset: 0, end_offset: 5, excerpt: "Alice"
    )
    assert_same span, span.validate!(document)
    assert_raises(KnowledgeExtraction::EvidenceMismatch) do
      KnowledgeExtraction::EvidenceSpan.new(
        source_id: document.source_id, start_offset: 0, end_offset: 5, excerpt: "Wrong"
      ).validate!(document)
    end
    assert_raises(KnowledgeExtraction::EvidenceMismatch) do
      KnowledgeExtraction::EvidenceSpan.new(
        source_id: document.source_id, start_offset: 0, end_offset: 99, excerpt: "Alice"
      ).validate!(document)
    end
  end

  def test_pdf_and_transcript_evidence_can_use_native_locators
    page = KnowledgeExtraction::EvidenceSpan.new(source_id: "source_x", excerpt: "Page text", page: 2)
    timed = KnowledgeExtraction::EvidenceSpan.new(
      source_id: "source_x", excerpt: "Speaker text", timestamp_start: 2.5,
      timestamp_end: 4.0, speaker: "Alice"
    )
    assert_equal 2, page.page
    assert_equal "Alice", timed.speaker
    assert_raises(KnowledgeExtraction::EvidenceMismatch) do
      KnowledgeExtraction::EvidenceSpan.new(source_id: "source_x", excerpt: "orphan")
    end
  end

  def test_fact_models_are_strict_immutable_and_serializable
    document = extraction_document
    validated = KnowledgeExtraction::StructuredOutputValidator.new.validate(
      KnowledgeExtraction::RawExtractionResult.new(
        payload: raw_relationship(document), provider_name: "fake", prompt_version: "v1"
      ),
      document
    )
    fact = validated.facts.first
    assert_equal "relationship", fact.fact_type
    assert_equal 0.98, fact.confidence
    assert fact.frozen?
    assert fact.subject.frozen?
    assert JSON.parse(fact.to_json).key?("fact_id")
    assert_raises(FrozenError) { fact.qualifiers["x"] = true }
    assert_raises(KnowledgeExtraction::FactValidationFailure) do
      KnowledgeExtraction::ScalarValue.new(value: "x", value_type: "unsupported")
    end
  end

  def test_confidence_and_status_are_enforced
    document = extraction_document
    evidence = KnowledgeExtraction::EvidenceSpan.new(**evidence_hash(document, document.content).transform_keys(&:to_sym))
    mention = KnowledgeExtraction::EntityMention.new(entity_type: "person", display_name: "Alice", evidence: [evidence])
    scalar = KnowledgeExtraction::ScalarValue.new(value: "x")
    assert_raises(ArgumentError) do
      KnowledgeExtraction::ExtractedFact.new(
        fact_type: "attribute", subject: mention, predicate: "legal_name", object: scalar,
        confidence: 1.1, evidence: [evidence]
      )
    end
    assert_raises(KnowledgeExtraction::FactValidationFailure) do
      KnowledgeExtraction::ExtractedFact.new(
        fact_type: "attribute", subject: mention, predicate: "legal_name", object: scalar,
        confidence: 0.8, evidence: [evidence], status: "maybe"
      )
    end
  end

  def test_date_normalization_preserves_expression_and_requires_context
    dates = KnowledgeExtraction::DateNormalizer.new
    yesterday = dates.normalize("yesterday", captured_at: FIXED_TIME)
    assert_equal "yesterday", yesterday.original_expression
    assert_equal "2026-07-28", yesterday.normalized_value
    assert_equal "2026-08-04", dates.normalize("next Tuesday", captured_at: FIXED_TIME).normalized_value
    assert_nil dates.normalize("next Tuesday").normalized_value
    assert dates.normalize("next week", captured_at: FIXED_TIME).uncertain
    assert_equal "2026-07-29", dates.normalize("2026-07-29").normalized_value
    assert_equal "2026-05-29", dates.normalize("two months ago", captured_at: FIXED_TIME).normalized_value
    assert_equal "weekly", dates.normalize("every Friday", captured_at: FIXED_TIME).normalized_value.fetch(:frequency)
    assert_equal({ from: "2026-07-01", to: "2026-07-05" },
                 dates.normalize("2026-07-01 to 2026-07-05").normalized_value)
  end

  def test_configuration_has_no_hidden_globals_and_round_trips
    configuration = KnowledgeExtraction::Configuration.new(
      minimum_fact_confidence: 0.5, provider_name: "fake", model_name: "fixture"
    )
    copy = KnowledgeExtraction::Configuration.new(**configuration.to_h)
    assert_equal configuration.to_h, copy.to_h
    assert configuration.frozen?
    assert_raises(ArgumentError) do
      KnowledgeExtraction::Configuration.new(
        minimum_entity_resolution_confidence: 0.9,
        automatic_candidate_resolution_threshold: 0.8
      )
    end
  end
end
