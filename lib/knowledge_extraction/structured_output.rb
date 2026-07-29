# frozen_string_literal: true

module KnowledgeExtraction
  class ValidatedExtraction < ImmutableModel
    attr_reader :summary, :mentions, :facts, :warnings, :rejected_items, :provider_metadata

    def initialize(summary:, mentions:, facts:, warnings:, rejected_items:, provider_metadata:)
      @summary = summary.to_s.freeze
      @mentions = immutable(mentions)
      @facts = immutable(facts)
      @warnings = immutable(warnings.map(&:to_s))
      @rejected_items = immutable(rejected_items)
      @provider_metadata = immutable(provider_metadata)
      freeze
    end

    def to_h
      {
        summary: summary, mentions: mentions.map(&:to_h), facts: facts.map(&:to_h),
        warnings: warnings, rejected_items: rejected_items.map(&:to_h),
        provider_metadata: provider_metadata
      }
    end
  end

  class StructuredOutputValidator
    TOP_LEVEL_FIELDS = %w[summary mentions facts warnings].freeze
    MENTION_FIELDS = %w[
      mention_id entity_type display_name aliases email phone external_ids organization role context evidence
    ].freeze
    FACT_FIELDS = %w[
      fact_id fact_type subject_mention_id predicate object qualifiers confidence evidence extraction_method status inference
    ].freeze
    OBJECT_FIELDS = %w[
      kind mention_id value value_type original_expression normalized_value normalization_confidence uncertain
    ].freeze
    EVIDENCE_FIELDS = %w[
      evidence_id source_id start_offset end_offset excerpt page paragraph speaker timestamp_start timestamp_end
    ].freeze

    def initialize(configuration: Configuration.new)
      @configuration = configuration
    end

    def validate(raw_result, document)
      payload = stringify(raw_result.payload)
      unknown = payload.keys - TOP_LEVEL_FIELDS
      unless unknown.empty?
        raise MalformedStructuredOutput, "unknown top-level fields: #{unknown.join(', ')}"
      end
      raise MalformedStructuredOutput, "mentions must be an array" unless payload.fetch("mentions", []).is_a?(Array)
      raise MalformedStructuredOutput, "facts must be an array" unless payload.fetch("facts", []).is_a?(Array)

      rejected = []
      mentions = parse_mentions(payload.fetch("mentions", []), document, rejected)
      mentions_by_id = mentions.to_h { |mention| [mention.mention_id, mention] }
      facts = parse_facts(payload.fetch("facts", []), document, mentions_by_id, rejected)
      facts = deduplicate(facts, rejected)
      ValidatedExtraction.new(
        summary: payload.fetch("summary", ""), mentions: mentions, facts: facts,
        warnings: Array(payload.fetch("warnings", [])), rejected_items: rejected,
        provider_metadata: {
          provider: raw_result.provider_name, model: raw_result.model_name,
          prompt_version: raw_result.prompt_version, token_usage: raw_result.token_usage,
          request_id: raw_result.request_id
        }
      )
    end

    private

    def parse_mentions(items, document, rejected)
      items.each_with_object([]) do |item, accepted|
        begin
          data = strict_object(item, MENTION_FIELDS, "mention")
          type = data.fetch("entity_type").to_s
          unless @configuration.allowed_entity_types.include?(type)
            raise FactValidationFailure, "unsupported entity type #{type.inspect}"
          end
          evidence = parse_evidence(data.fetch("evidence", []), document)
          accepted << EntityMention.new(**symbolize(data.merge("evidence" => evidence)))
        rescue StandardError => error
          rejected << RejectedItem.new(item: safe_item(item), reason: error.message, stage: "mention_validation")
        end
      end
    end

    def parse_facts(items, document, mentions, rejected)
      items.each_with_object([]) do |item, accepted|
        begin
          data = strict_object(item, FACT_FIELDS, "fact")
          subject = mentions.fetch(data.fetch("subject_mention_id").to_s) do
            raise FactValidationFailure, "unknown subject mention"
          end
          object = parse_object(data.fetch("object"), mentions)
          evidence = parse_evidence(data.fetch("evidence"), document)
          accepted << ExtractedFact.new(
            fact_id: data["fact_id"], fact_type: data.fetch("fact_type"), subject: subject,
            predicate: data.fetch("predicate"), object: object,
            qualifiers: data.fetch("qualifiers", {}), confidence: data.fetch("confidence"),
            evidence: evidence, extraction_method: data.fetch("extraction_method", "provider"),
            status: data.fetch("status", "asserted"), inference: data.fetch("inference", false)
          )
        rescue StandardError => error
          rejected << RejectedItem.new(item: safe_item(item), reason: error.message, stage: "fact_validation")
        end
      end
    end

    def parse_object(value, mentions)
      data = strict_object(value, OBJECT_FIELDS, "fact object")
      case data.fetch("kind")
      when "mention"
        mentions.fetch(data.fetch("mention_id").to_s) do
          raise FactValidationFailure, "unknown object mention"
        end
      when "scalar"
        ScalarValue.new(**symbolize(data.reject { |key, _value| key == "kind" || key == "mention_id" }))
      else
        raise FactValidationFailure, "object kind must be mention or scalar"
      end
    end

    def parse_evidence(items, document)
      raise EvidenceMismatch, "evidence must be a non-empty array" unless items.is_a?(Array) && !items.empty?

      items.map do |item|
        data = strict_object(item, EVIDENCE_FIELDS, "evidence")
        excerpt = data.fetch("excerpt").to_s
        if excerpt.length > @configuration.evidence_excerpt_length
          raise EvidenceMismatch, "evidence excerpt exceeds configured limit"
        end
        EvidenceSpan.new(**symbolize(data)).validate!(document)
      end
    end

    def deduplicate(facts, rejected)
      seen = {}
      facts.each_with_object([]) do |fact, accepted|
        signature = [
          fact.fact_type, fact.subject.mention_id, fact.predicate,
          Support.canonical_json(fact.object.to_h), Support.canonical_json(fact.qualifiers), fact.status
        ]
        if seen.key?(signature)
          rejected << RejectedItem.new(item: fact.to_h, reason: "duplicate fact", stage: "deduplication")
        else
          seen[signature] = true
          accepted << fact
        end
      end
    end

    def strict_object(value, allowed_fields, label)
      raise MalformedStructuredOutput, "#{label} must be an object" unless value.is_a?(Hash)

      data = stringify(value)
      unknown = data.keys - allowed_fields
      raise MalformedStructuredOutput, "unknown #{label} fields: #{unknown.join(', ')}" unless unknown.empty?

      data
    end

    def stringify(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end

    def symbolize(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_sym] = value }
    end

    def safe_item(item)
      Support.canonical(item)
    rescue StandardError
      item.to_s[0, 1_000]
    end
  end
end
