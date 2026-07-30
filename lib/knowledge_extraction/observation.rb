# frozen_string_literal: true

require "digest"

module KnowledgeExtraction
  class ObservationEnvelope < ImmutableModel
    SENSITIVITIES = %w[normal private restricted].freeze

    attr_reader :observation_id, :text, :source, :conversation, :message_id,
                :sender, :timestamp, :source_type, :sensitivity, :content_hash

    def initialize(text:, source: "cli", conversation: nil, message_id: nil,
                   sender: nil, timestamp: nil, source_type: nil,
                   sensitivity: "private", clock: nil)
      @text = Support.normalized_text(text).freeze
      raise NormalizationFailure, "observation text is empty" if @text.strip.empty?

      @source = required_string(source, "observation source", maximum: 200)
      @conversation = optional_string(conversation, "conversation", maximum: 1_000)
      @message_id = optional_string(message_id, "message id", maximum: 1_000)
      @sender = optional_string(sender, "sender", maximum: 1_000)
      supplied_time = timestamp.to_s.strip.empty? ? (clock || -> { Time.now }).call : timestamp
      @timestamp = Support.parse_time(supplied_time, field: "observation timestamp")
      @sensitivity = sensitivity.to_s.freeze
      unless SENSITIVITIES.include?(@sensitivity)
        raise ArgumentError, "sensitivity must be normal, private, or restricted"
      end
      @source_type = resolve_source_type(source_type).freeze
      @content_hash = Digest::SHA256.hexdigest(@text).freeze
      @observation_id = Support.stable_id("observation", *identity_parts).freeze
      freeze
    end

    def gateway_arguments
      Support.compact_hash(
        "source_type" => source_type,
        "content" => text,
        "captured_at" => timestamp.iso8601(6),
        "external_id" => observation_id,
        "sensitivity" => sensitivity,
        "observation_id" => observation_id,
        "origin_source" => source,
        "conversation_id" => conversation,
        "message_id" => message_id,
        "sender" => sender
      )
    end

    def event_payload
      Support.compact_hash(
        "observation_id" => observation_id,
        "source" => source,
        "source_type" => source_type,
        "conversation_id" => conversation,
        "message_id" => message_id,
        "sender" => sender,
        "timestamp" => timestamp.iso8601(6),
        "content_hash" => content_hash,
        "sensitivity" => sensitivity
      )
    end

    def to_h(include_text: false)
      value = event_payload.merge("observation_id" => observation_id)
      value["text"] = text if include_text
      value
    end

    private

    def resolve_source_type(explicit)
      candidate = explicit.to_s.strip
      unless candidate.empty?
        unless SourceDocument::TYPES.include?(candidate)
          raise UnsupportedSource, "unsupported observation source type #{candidate.inspect}"
        end
        return candidate
      end
      return source if SourceDocument::TYPES.include?(source)
      return "chat" if conversation || message_id

      "text"
    end

    def identity_parts
      return [source, conversation, message_id] if message_id

      [source, conversation, timestamp.iso8601(6), content_hash]
    end
  end

  class ObservationResult
    JSON_SCHEMA = Support.deep_freeze(
      "type" => "object",
      "required" => %w[status observation_id events summary proposals cache],
      "properties" => {
        "status" => { "type" => "string", "enum" => %w[ok clarification_required] },
        "observation_id" => {
          "type" => "string", "pattern" => "^observation_[0-9A-HJKMNP-TV-Z]{26}$"
        },
        "events" => {
          "type" => "array", "minItems" => 1, "uniqueItems" => true,
          "items" => { "type" => "string" }
        },
        "summary" => {
          "type" => "object",
          "required" => %w[entities_detected proposals_created approval_required],
          "properties" => {
            "entities_detected" => { "type" => "integer", "minimum" => 0 },
            "proposals_created" => { "type" => "integer", "minimum" => 0 },
            "approval_required" => { "type" => "boolean" }
          },
          "additionalProperties" => false
        },
        "proposals" => {
          "type" => "array",
          "items" => {
            "type" => "object", "required" => %w[id type status],
            "properties" => {
              "id" => { "type" => "string" },
              "type" => { "type" => "string", "const" => "knowledge_update" },
              "status" => { "type" => "string" }
            },
            "additionalProperties" => false
          }
        },
        "cache" => {
          "type" => "object", "required" => ["artifacts_created"],
          "properties" => {
            "artifacts_created" => {
              "type" => "array", "uniqueItems" => true,
              "items" => { "type" => "string" }
            }
          },
          "additionalProperties" => false
        },
        "question" => { "type" => "string" },
        "options" => {
          "type" => "array",
          "items" => {
            "type" => "object",
            "required" => %w[mention_id entity_id display_name entity_type score],
            "properties" => {
              "mention_id" => { "type" => "string" },
              "entity_id" => { "type" => "string" },
              "display_name" => { "type" => ["string", "null"] },
              "entity_type" => { "type" => "string" },
              "score" => { "type" => "number", "minimum" => 0.0, "maximum" => 1.0 }
            },
            "additionalProperties" => false
          }
        },
        "explain" => { "type" => "array", "items" => { "type" => "string" } }
      },
      "additionalProperties" => false
    )

    attr_reader :payload, :detected, :stages

    def initialize(payload:, detected:, stages:)
      @payload = Support.deep_freeze(Support.canonical(payload))
      @detected = Array(detected).map(&:to_s).uniq.freeze
      @stages = Array(stages).map(&:to_s).freeze
      validate_payload!(@payload)
      freeze
    end

    def to_h(explain: false)
      value = Support.canonical(payload)
      value["explain"] = stages if explain
      validate_payload!(value)
      value
    end

    private

    def validate_payload!(value)
      AgentPlatform::SchemaValidator.new.validate!(JSON_SCHEMA, value, label: "observation response")
      return true unless value.fetch("status") == "clarification_required"

      if value["question"].to_s.empty? || Array(value["options"]).empty?
        raise ObservationFailure, "clarification response is missing a question or options"
      end
      true
    end
  end

  class ObservationPipeline
    EXTRACTION_CAPABILITY = "kg.extraction.extract_source"
    VALIDATION_CAPABILITY = "kg.proposals.validate"
    CACHE_TYPES = %w[knowledge_extraction entity_resolution].freeze
    INVALIDATING_EVENT_TYPES = %w[GraphChanged RelationshipUpdated ContactCreated].freeze

    def initialize(gateway:, agent:, event_bus:, cache:, proposal_store:, snapshot_provider:)
      @gateway = gateway
      @agent = agent
      @event_bus = event_bus
      @cache = cache
      @proposal_store = proposal_store
      @snapshot_provider = snapshot_provider
    end

    def process(envelope)
      raise ObservationFailure, "ObservationPipeline expects an ObservationEnvelope" unless envelope.is_a?(ObservationEnvelope)

      snapshot_digest = current_snapshot_digest
      trace_id = Support.stable_id("trace", envelope.observation_id)
      events = []
      stages = ["Observation normalized"]
      events << publish("ObservationReceived", envelope.event_payload, envelope, trace_id)
      events << publish(
        "ObservationParsed",
        envelope.event_payload.slice("observation_id", "source_type", "content_hash"),
        envelope, trace_id, events.last.id
      )

      extraction_contract = contract_for(EXTRACTION_CAPABILITY)
      extraction_policy = policy_for(extraction_contract, envelope.gateway_arguments)
      extraction = invoke(extraction_contract, envelope.gateway_arguments, trace_id)
      proposal_id = extraction.payload.fetch("proposal_id")
      proposal = @proposal_store.load(proposal_id)
      ensure_graph_unchanged!(snapshot_digest)

      stages.concat(["Extraction completed", "Entity resolution completed", "Proposal generated"])
      events << publish(
        "ExtractionCompleted",
        {
          "observation_id" => envelope.observation_id,
          "proposal_id" => proposal_id,
          "fact_count" => proposal.fetch("facts").length,
          "entities_detected" => proposal.fetch("entity_mentions").length
        },
        envelope, trace_id, events.last.id
      )
      events << publish(
        "ProposalCreated",
        {
          "observation_id" => envelope.observation_id,
          "proposal_id" => proposal_id,
          "status" => proposal.fetch("status"),
          "executable" => false
        },
        envelope, trace_id, events.last.id
      )

      validation_arguments = { "proposal_id" => proposal_id }
      validation_contract = contract_for(VALIDATION_CAPABILITY)
      validation_policy = policy_for(validation_contract, validation_arguments)
      validation = invoke(validation_contract, validation_arguments, trace_id)
      approval_required = approval_required?(proposal)
      stages << "Policy validation passed"
      events << publish(
        "PolicyValidated",
        {
          "observation_id" => envelope.observation_id,
          "proposal_id" => proposal_id,
          "validation_status" => validation.payload.fetch("status"),
          "approval_required" => approval_required,
          "capabilities" => [
            policy_summary(extraction_contract, extraction_policy),
            policy_summary(validation_contract, validation_policy)
          ]
        },
        envelope, trace_id, events.last.id
      )

      artifacts = cache_artifacts(
        envelope: envelope, proposal: proposal, events: events,
        snapshot_digest: snapshot_digest,
        capability_id: extraction.capability_id,
        capability_version: extraction.capability_version
      )
      status = ambiguous?(proposal) ? "clarification_required" : "ok"
      stages << if status == "clarification_required"
                  "Clarification required"
                elsif approval_required
                  "Approval required"
                else
                  "Review ready"
                end
      events << publish(
        "ObservationCompleted",
        {
          "observation_id" => envelope.observation_id,
          "proposal_id" => proposal_id,
          "status" => status,
          "artifact_ids" => artifacts.map(&:id)
        },
        envelope, trace_id, events.last.id
      )

      payload = response_payload(
        envelope: envelope, proposal: proposal, events: events,
        artifacts: artifacts, approval_required: approval_required, status: status
      )
      ObservationResult.new(payload: payload, detected: detected_labels(proposal), stages: stages)
    rescue KeyError => error
      raise ObservationFailure, "observation pipeline returned incomplete data: #{error.key}"
    end

    private

    def contract_for(capability_id)
      @gateway.discover(agent: @agent).find do |item|
        item.fetch("capability_id") == capability_id
      end || raise(ObservationFailure, "required capability is unavailable under policy: #{capability_id}")
    end

    def policy_for(contract, arguments)
      decision = Support.canonical(@gateway.policy_check(
        invocation_token: contract.fetch("invocation_token"), arguments: arguments, agent: @agent
      ))
      unless decision.fetch("allowed")
        raise ObservationFailure, "policy denied #{contract.fetch('capability_id')}: #{decision.fetch('reason')}"
      end

      decision
    end

    def invoke(contract, arguments, trace_id)
      request = @gateway.issue_request(
        invocation_token: contract.fetch("invocation_token"), arguments: arguments, trace_id: trace_id
      )
      response = @gateway.execute(request: request, agent: @agent)
      return response if response.success?

      error = response.errors.first || { "code" => "ExecutionFailed", "message" => "capability failed" }
      raise ObservationFailure, "#{error.fetch('code')}: #{error.fetch('message')}"
    end

    def publish(type, payload, envelope, trace_id, causation_id = nil)
      @event_bus.publish(
        type: type, source: "kg.observe", payload: payload,
        correlation_id: envelope.observation_id, causation_id: causation_id, trace_id: trace_id
      )
    end

    def current_snapshot_digest
      snapshot = @snapshot_provider.call
      snapshot.respond_to?(:digest) ? snapshot.digest.to_s : snapshot.to_s
    end

    def ensure_graph_unchanged!(expected)
      return if current_snapshot_digest == expected

      raise ObservationFailure, "canonical graph changed while processing the observation"
    end

    def approval_required?(proposal)
      Integer(proposal.fetch("required_approvals").fetch("total")) > 0
    end

    def ambiguous?(proposal)
      proposal.fetch("resolution_decisions").any? do |decision|
        %w[ambiguous conflict].include?(decision.fetch("outcome"))
      end
    end

    def policy_summary(contract, decision)
      {
        "capability_id" => contract.fetch("capability_id"),
        "capability_version" => contract.fetch("version"),
        "allowed" => decision.fetch("allowed"),
        "approval" => decision.fetch("approval")
      }
    end

    def cache_artifacts(envelope:, proposal:, events:, snapshot_digest:, capability_id:, capability_version:)
      entity_ids = entity_scope(proposal)
      dependencies = KnowledgeOrchestration::ArtifactDependencies.new(
        observation_ids: [envelope.observation_id],
        event_ids: events.map(&:id),
        event_types: INVALIDATING_EVENT_TYPES,
        entity_ids: entity_ids,
        snapshot_digest: snapshot_digest,
        capability_id: capability_id,
        capability_version: capability_version
      )
      values = {
        "knowledge_extraction" => {
          "observation_id" => envelope.observation_id,
          "proposal_id" => proposal.fetch("proposal_id"),
          "fact_count" => proposal.fetch("facts").length,
          "entity_mention_count" => proposal.fetch("entity_mentions").length,
          "planned_intent_count" => proposal.fetch("planned_intents").length,
          "proposal_status" => proposal.fetch("status"),
          "ingestion_state" => proposal.fetch("ingestion_state")
        },
        "entity_resolution" => {
          "observation_id" => envelope.observation_id,
          "proposal_id" => proposal.fetch("proposal_id"),
          "outcomes" => resolution_outcomes(proposal),
          "ambiguous_mention_ids" => ambiguous_mention_ids(proposal)
        }
      }
      CACHE_TYPES.map do |artifact_type|
        cache_key = @cache.key(
          capability_id: capability_id,
          capability_version: capability_version,
          arguments: {
            "observation_id" => envelope.observation_id,
            "proposal_id" => proposal.fetch("proposal_id"),
            "artifact_type" => artifact_type
          },
          snapshot_digest: snapshot_digest
        )
        @cache.write(
          artifact_type: artifact_type, cache_key: cache_key,
          value: values.fetch(artifact_type), dependencies: dependencies,
          metadata: { "derived" => true, "stage" => artifact_type }
        )
      end
    end

    def entity_scope(proposal)
      proposal.fetch("resolution_decisions").flat_map do |decision|
        [decision["selected_entity_id"]] + decision.fetch("candidates").map do |candidate|
          candidate.fetch("canonical_entity_id")
        end
      end.compact.map(&:to_s).uniq.sort
    end

    def resolution_outcomes(proposal)
      proposal.fetch("resolution_decisions").each_with_object(Hash.new(0)) do |decision, counts|
        counts[decision.fetch("outcome")] += 1
      end.sort.to_h
    end

    def ambiguous_mention_ids(proposal)
      proposal.fetch("resolution_decisions").map do |decision|
        decision.fetch("mention_id") if %w[ambiguous conflict].include?(decision.fetch("outcome"))
      end.compact.sort
    end

    def response_payload(envelope:, proposal:, events:, artifacts:, approval_required:, status:)
      payload = {
        "status" => status,
        "observation_id" => envelope.observation_id,
        "events" => events.map(&:type),
        "summary" => {
          "entities_detected" => proposal.fetch("entity_mentions").length,
          "proposals_created" => 1,
          "approval_required" => approval_required
        },
        "proposals" => [{
          "id" => proposal.fetch("proposal_id"),
          "type" => "knowledge_update",
          "status" => public_proposal_status(proposal.fetch("status"))
        }],
        "cache" => { "artifacts_created" => artifacts.map(&:artifact_type) }
      }
      payload.merge!(clarification(proposal)) if status == "clarification_required"
      payload
    end

    def public_proposal_status(status)
      case status
      when "awaiting_approval" then "pending_approval"
      when "resolution_required" then "clarification_required"
      when "planned" then "pending_review"
      else status
      end
    end

    def clarification(proposal)
      mentions = proposal.fetch("entity_mentions").to_h do |mention|
        [mention.fetch("mention_id"), mention.fetch("display_name")]
      end
      decisions = proposal.fetch("resolution_decisions").select do |decision|
        %w[ambiguous conflict].include?(decision.fetch("outcome"))
      end
      names = decisions.map { |decision| mentions[decision.fetch("mention_id")] }.compact.uniq
      question = if names.length == 1
                   "Multiple identities match #{names.first}. Which one do you mean?"
                 else
                   "Multiple identities match this observation. Which ones do you mean?"
                 end
      options = decisions.flat_map do |decision|
        decision.fetch("candidates").map do |candidate|
          {
            "mention_id" => decision.fetch("mention_id"),
            "entity_id" => candidate.fetch("canonical_entity_id"),
            "display_name" => candidate["display_name"],
            "entity_type" => candidate.fetch("entity_type"),
            "score" => candidate.fetch("score")
          }
        end
      end.uniq { |option| [option.fetch("mention_id"), option.fetch("entity_id")] }
      { "question" => question, "options" => options }
    end

    def detected_labels(proposal)
      entities = proposal.fetch("entity_mentions").map { |mention| mention.fetch("display_name") }
      predicates = proposal.fetch("facts").map do |fact|
        fact["predicate"]&.tr("_", " ")&.split&.map(&:capitalize)&.join(" ")
      end.compact
      (entities + predicates).uniq
    end
  end
end
