# frozen_string_literal: true

require_relative "../test_helper"

module KnowledgeExtractionTestSupport
  FIXED_TIME = Time.new(2026, 7, 29, 12, 0, 0, "+03:00")

  def extraction_configuration(root = nil, **overrides)
    if root
      reader = KnowledgeGraph::GraphReader.new(vault_root: root)
      defaults = { allowed_entity_types: reader.entity_types, allowed_predicates: reader.predicates }
    else
      defaults = {}
    end
    KnowledgeExtraction::Configuration.new(**defaults.merge(overrides))
  end

  def raw_relationship(document, subject: "Alice Carter", subject_type: "person",
                       predicate: "works_for", object: "Northstar", object_type: "organization",
                       confidence: 0.98, status: "asserted", qualifiers: {})
    subject_id = KnowledgeExtraction::Support.stable_id("mention", document.source_id, subject)
    object_id = KnowledgeExtraction::Support.stable_id("mention", document.source_id, object)
    {
      "summary" => "Synthetic relationship",
      "mentions" => [
        mention_hash(document, subject_id, subject_type, subject),
        mention_hash(document, object_id, object_type, object)
      ],
      "facts" => [
        {
          "fact_type" => "relationship", "subject_mention_id" => subject_id,
          "predicate" => predicate,
          "object" => { "kind" => "mention", "mention_id" => object_id },
          "qualifiers" => qualifiers, "confidence" => confidence, "status" => status,
          "evidence" => [evidence_hash(document, document.content)]
        }
      ],
      "warnings" => []
    }
  end

  def mention_hash(document, mention_id, entity_type, display_name, **extra)
    {
      "mention_id" => mention_id, "entity_type" => entity_type,
      "display_name" => display_name,
      "evidence" => [evidence_hash(document, display_name)]
    }.merge(extra.transform_keys(&:to_s))
  end

  def evidence_hash(document, excerpt)
    start = document.content.index(excerpt)
    raise "fixture excerpt missing: #{excerpt}" unless start

    {
      "source_id" => document.source_id, "start_offset" => start,
      "end_offset" => start + excerpt.length, "excerpt" => excerpt
    }
  end

  def extraction_document(content = "Alice Carter works at Northstar.", **options)
    KnowledgeExtraction::SourceDocument.new(
      source_type: options.delete(:source_type) || "text", content: content,
      language: options.delete(:language) || "en", captured_at: FIXED_TIME,
      **options
    )
  end

  def pipeline_for(root, payload, store: nil, configuration: nil)
    reader = KnowledgeGraph::GraphReader.new(vault_root: root)
    config = configuration || extraction_configuration(root, provider_name: "fake")
    KnowledgeExtraction::KnowledgeExtractionPipeline.new(
      graph_reader: reader, provider: KnowledgeExtraction::FakeExtractionProvider.new(payload),
      configuration: config, proposal_store: store, clock: -> { FIXED_TIME }
    )
  end
end

class Minitest::Test
  include KnowledgeExtractionTestSupport
end
