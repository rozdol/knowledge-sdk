# frozen_string_literal: true

module KnowledgeExtraction
  class ScalarValue < ImmutableModel
    TYPES = %w[string number boolean date datetime date-range duration recurrence location json unknown].freeze
    attr_reader :value, :value_type, :original_expression, :normalized_value,
                :normalization_confidence, :uncertain

    def initialize(value:, value_type: "string", original_expression: nil,
                   normalized_value: nil, normalization_confidence: 1.0, uncertain: false)
      @value = immutable(value)
      @value_type = value_type.to_s.freeze
      raise FactValidationFailure, "unsupported scalar value_type #{@value_type.inspect}" unless TYPES.include?(@value_type)
      @original_expression = optional_string(original_expression, "original_expression", maximum: 2_000)
      @normalized_value = immutable(normalized_value)
      @normalization_confidence = validated_confidence(normalization_confidence, "normalization_confidence")
      @uncertain = !!uncertain
      freeze
    end

    def to_h
      {
        value: value, value_type: value_type, original_expression: original_expression,
        normalized_value: normalized_value, normalization_confidence: normalization_confidence,
        uncertain: uncertain
      }
    end
  end

  class EntityMention < ImmutableModel
    attr_reader :mention_id, :entity_type, :display_name, :aliases, :email, :phone,
                :external_ids, :organization, :role, :context, :evidence

    def initialize(entity_type:, display_name:, mention_id: nil, aliases: [], email: nil,
                   phone: nil, external_ids: [], organization: nil, role: nil,
                   context: nil, evidence: [])
      @entity_type = required_string(entity_type, "entity_type", maximum: 100)
      @display_name = required_string(display_name, "display_name", maximum: 500)
      @aliases = immutable(Array(aliases).map(&:to_s).uniq)
      @email = optional_string(email, "email", maximum: 500)
      @phone = optional_string(phone, "phone", maximum: 100)
      @external_ids = immutable(Array(external_ids).map(&:to_s).uniq)
      @organization = optional_string(organization, "organization", maximum: 500)
      @role = optional_string(role, "role", maximum: 500)
      @context = optional_string(context, "context", maximum: 2_000)
      @evidence = immutable(Array(evidence))
      @mention_id = (mention_id || Support.stable_id(
        "mention", @entity_type, @display_name, @email, @phone, @external_ids.join("|")
      )).to_s.freeze
      freeze
    end

    def to_h
      Support.compact_hash(
        mention_id: mention_id, entity_type: entity_type, display_name: display_name,
        aliases: aliases, email: email, phone: phone, external_ids: external_ids,
        organization: organization, role: role, context: context,
        evidence: evidence.map(&:to_h)
      )
    end
  end

  class ExtractedFact < ImmutableModel
    TYPES = %w[entity attribute relationship interaction meeting promise follow-up introduction correction dataset_observation].freeze
    STATUSES = %w[asserted negated uncertain corrected superseded planned historical].freeze

    attr_reader :fact_id, :fact_type, :subject, :predicate, :object, :qualifiers,
                :confidence, :evidence, :extraction_method, :status, :inference

    def initialize(fact_type:, subject:, predicate:, object:, confidence:, evidence:,
                   fact_id: nil, qualifiers: {}, extraction_method: "provider",
                   status: "asserted", inference: false)
      @fact_type = fact_type.to_s.freeze
      raise FactValidationFailure, "unsupported fact_type #{@fact_type.inspect}" unless TYPES.include?(@fact_type)
      unless subject.is_a?(EntityMention)
        raise FactValidationFailure, "fact subject must be an EntityMention"
      end
      @subject = subject
      @predicate = required_string(predicate, "predicate", maximum: 200)
      unless object.is_a?(EntityMention) || object.is_a?(ScalarValue)
        raise FactValidationFailure, "fact object must be an EntityMention or ScalarValue"
      end
      @object = object
      @qualifiers = immutable(qualifiers || {})
      @confidence = validated_confidence(confidence)
      @evidence = immutable(Array(evidence))
      raise FactValidationFailure, "fact evidence is required" if @evidence.empty?
      unless @evidence.all? { |item| item.is_a?(EvidenceSpan) }
        raise FactValidationFailure, "fact evidence must contain EvidenceSpan values"
      end
      @extraction_method = required_string(extraction_method, "extraction_method", maximum: 200)
      @status = status.to_s.freeze
      raise FactValidationFailure, "unsupported fact status #{@status.inspect}" unless STATUSES.include?(@status)
      @inference = !!inference
      @fact_id = (fact_id || Support.stable_id(
        "fact", @fact_type, @subject.mention_id, @predicate, Support.canonical_json(@object),
        Support.canonical_json(@qualifiers), @status, @evidence.map(&:evidence_id).join("|")
      )).to_s.freeze
      freeze
    end

    def to_h
      {
        fact_id: fact_id, fact_type: fact_type, subject: subject.to_h,
        predicate: predicate, object: object.to_h, object_kind: object.class.name.split("::").last,
        qualifiers: qualifiers, confidence: confidence, evidence: evidence.map(&:to_h),
        extraction_method: extraction_method, status: status, inference: inference
      }
    end
  end

  class RejectedItem < ImmutableModel
    attr_reader :item, :reason, :stage

    def initialize(item:, reason:, stage:)
      @item = immutable(item)
      @reason = required_string(reason, "reason", maximum: 2_000)
      @stage = required_string(stage, "stage", maximum: 100)
      freeze
    end

    def to_h
      { item: item.respond_to?(:to_h) ? item.to_h : item, reason: reason, stage: stage }
    end
  end
end
