# frozen_string_literal: true

module KnowledgeExtraction
  class Configuration < ImmutableModel
    ENTITY_TYPES = %w[
      person organization interaction introduction place project book interest technology country city event
      commitment follow-up relationship language profession industry dataset
    ].freeze
    LANGUAGES = %w[en ru el mixed und].freeze
    APPROVAL_POLICIES = %w[review_all allow_low_risk].freeze
    REDACTION_POLICIES = %w[metadata_only redact_secrets].freeze

    attr_reader :minimum_fact_confidence, :minimum_entity_resolution_confidence,
                :automatic_candidate_resolution_threshold, :allowed_entity_types,
                :allowed_predicates, :supported_languages, :evidence_excerpt_length,
                :source_size_limit, :prompt_version, :pipeline_version, :provider_name,
                :model_name, :temperature, :approval_policy, :redaction_policy,
                :context_limit, :debug, :external_provider_enabled

    def initialize(minimum_fact_confidence: 0.40, minimum_entity_resolution_confidence: 0.60,
                   automatic_candidate_resolution_threshold: 0.95,
                   allowed_entity_types: ENTITY_TYPES, allowed_predicates: [],
                   supported_languages: LANGUAGES, evidence_excerpt_length: 240,
                   source_size_limit: 1_000_000, prompt_version: "ke-prompt-v1",
                   pipeline_version: "5.0.0", provider_name: "deterministic",
                   model_name: nil, temperature: 0.0, approval_policy: "review_all",
                   redaction_policy: "redact_secrets", context_limit: 50,
                   debug: false, external_provider_enabled: false)
      @minimum_fact_confidence = validated_confidence(minimum_fact_confidence, "minimum_fact_confidence")
      @minimum_entity_resolution_confidence = validated_confidence(
        minimum_entity_resolution_confidence, "minimum_entity_resolution_confidence"
      )
      @automatic_candidate_resolution_threshold = validated_confidence(
        automatic_candidate_resolution_threshold, "automatic_candidate_resolution_threshold"
      )
      if @automatic_candidate_resolution_threshold < @minimum_entity_resolution_confidence
        raise ArgumentError, "automatic resolution threshold must not be below the candidate threshold"
      end
      @allowed_entity_types = validate_subset(allowed_entity_types, ENTITY_TYPES, "entity type")
      @allowed_predicates = Array(allowed_predicates).map(&:to_s).uniq.sort.freeze
      @supported_languages = validate_subset(supported_languages, LANGUAGES, "language")
      @evidence_excerpt_length = positive_integer(evidence_excerpt_length, "evidence_excerpt_length", 2_000)
      @source_size_limit = positive_integer(source_size_limit, "source_size_limit", 10_000_000)
      @prompt_version = required_string(prompt_version, "prompt_version", maximum: 100)
      @pipeline_version = required_string(pipeline_version, "pipeline_version", maximum: 100)
      @provider_name = required_string(provider_name, "provider_name", maximum: 100)
      @model_name = optional_string(model_name, "model_name", maximum: 200)
      @temperature = Float(temperature)
      raise ArgumentError, "temperature must be between 0 and 2" unless @temperature.between?(0.0, 2.0)
      @approval_policy = enum(approval_policy, APPROVAL_POLICIES, "approval_policy")
      @redaction_policy = enum(redaction_policy, REDACTION_POLICIES, "redaction_policy")
      @context_limit = positive_integer(context_limit, "context_limit", 1_000)
      @debug = !!debug
      @external_provider_enabled = !!external_provider_enabled
      freeze
    end

    def to_h
      {
        minimum_fact_confidence: minimum_fact_confidence,
        minimum_entity_resolution_confidence: minimum_entity_resolution_confidence,
        automatic_candidate_resolution_threshold: automatic_candidate_resolution_threshold,
        allowed_entity_types: allowed_entity_types,
        allowed_predicates: allowed_predicates,
        supported_languages: supported_languages,
        evidence_excerpt_length: evidence_excerpt_length,
        source_size_limit: source_size_limit,
        prompt_version: prompt_version,
        pipeline_version: pipeline_version,
        provider_name: provider_name,
        model_name: model_name,
        temperature: temperature,
        approval_policy: approval_policy,
        redaction_policy: redaction_policy,
        context_limit: context_limit,
        debug: debug,
        external_provider_enabled: external_provider_enabled
      }
    end

    private

    def validate_subset(values, allowed, label)
      normalized = Array(values).map(&:to_s).uniq.sort
      unknown = normalized - allowed
      raise ArgumentError, "unsupported #{label}: #{unknown.join(', ')}" unless unknown.empty?

      normalized.freeze
    end

    def positive_integer(value, field, maximum)
      number = Integer(value)
      raise ArgumentError, "#{field} must be between 1 and #{maximum}" unless number.between?(1, maximum)

      number
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{field} must be between 1 and #{maximum}"
    end

    def enum(value, allowed, field)
      string = value.to_s
      raise ArgumentError, "invalid #{field}: #{value.inspect}" unless allowed.include?(string)

      string.freeze
    end
  end
end
