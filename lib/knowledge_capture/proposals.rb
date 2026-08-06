# frozen_string_literal: true

module KnowledgeCapture
  class ProposalFactory
    def initialize(vault_root:, proposal_store: nil, event_bus: nil, clock: nil)
      @vault_root = vault_root
      @clock = clock || -> { Time.now }
      @store = proposal_store || KnowledgeExtraction::ProposalStore.new(vault_root: vault_root, clock: @clock)
      @event_bus = event_bus
    end

    def persist(document:, planned_intents:, summary:, model_metadata:, confidence:)
      proposal_id = KnowledgeExtraction::Support.stable_id(
        "proposal", document.source_id, summary,
        KnowledgeExtraction::Support.canonical_json(
          planned_intents.map { |spec| spec.fetch(:intent).to_h }
        )
      )
      evidence_id = KnowledgeExtraction::Support.stable_id(
        "evidence", document.source_id, document.content_hash, "capture"
      )
      fact_id = KnowledgeExtraction::Support.stable_id("fact", document.source_id, "capture")
      planned = planned_intents.map do |spec|
        KnowledgeExtraction::PlannedIntent.new(
          planned_intent_id: spec.fetch(:planned_intent_id), intent: spec.fetch(:intent),
          fact_ids: [fact_id], evidence_ids: [evidence_id],
          planning_confidence: confidence, risk: spec.fetch(:risk, "medium"),
          approval_requirement: "human_review", dependencies: spec.fetch(:dependencies, []),
          blocked_reasons: [], provenance: {
            source_id: document.source_id, source_type: document.source_type,
            captured_at: document.captured_at&.iso8601
          }
        )
      end
      excerpt = document.content[0, 2_000]
      proposal = {
        "proposal_id" => proposal_id, "source" => stringify(document.metadata_only),
        "summary" => summary,
        "facts" => [{
          "fact_id" => fact_id, "fact_type" => "capture", "confidence" => confidence,
          "evidence" => [{
            "evidence_id" => evidence_id, "source_id" => document.source_id,
            "start_offset" => 0, "end_offset" => excerpt.length, "excerpt" => excerpt
          }]
        }],
        "entity_mentions" => [], "resolution_candidates" => [], "resolution_decisions" => [],
        "planned_intents" => planned.map { |item| stringify(item.to_h) },
        "warnings" => [], "conflicts" => [],
        "required_approvals" => {
          "total" => planned.length, "blocked" => 0,
          "by_risk" => {
            "low" => planned.count { |item| item.risk == "low" },
            "medium" => planned.count { |item| item.risk == "medium" },
            "high" => planned.count { |item| item.risk == "high" }
          }
        },
        "rejected_items" => [], "model_metadata" => model_metadata,
        "prompt_version" => "knowledge-capture-v1", "pipeline_version" => "16.0.0",
        "created_at" => (@clock.call).iso8601, "status" => "awaiting_approval",
        "ingestion_state" => @store.classify_source(document), "metrics" => {
          "proposed_intents" => planned.length, "capture_evidence" => 1
        }
      }
      @store.save(proposal)
      @store.record_source(document, proposal_id)
      KnowledgeExtraction::ProposalValidator.new.validate!(@store.load(proposal_id))
      publish(proposal_id, planned, document)
      [proposal, planned]
    end

    private

    def stringify(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = stringify(item) }
      when Array then value.map { |item| stringify(item) }
      else value
      end
    end

    def publish(proposal_id, planned, document)
      return unless @event_bus

      @event_bus.publish(
        type: "ProposalCreated", source: "knowledge-capture",
        payload: {
          "proposal_id" => proposal_id, "status" => "awaiting_approval",
          "planned_intent_count" => planned.length, "source_id" => document.source_id
        }, correlation_id: proposal_id
      )
    end
  end

  class CaptureProposalBuilder
    def initialize(vault_root:, proposal_store: nil, event_bus: nil, clock: nil,
                   registry: KnowledgeCapture.registry)
      @vault_root = vault_root
      @clock = clock || -> { Time.now }
      @registry = registry
      @factory = ProposalFactory.new(
        vault_root: vault_root, proposal_store: proposal_store, event_bus: event_bus, clock: @clock
      )
    end

    def create(arguments)
      values = arguments.transform_keys(&:to_s)
      content = values.fetch("content").to_s
      parsed = IntentClassifierPlugin.parse(content)
      raise InvalidCapture, "message is not an explicit Capture" unless parsed

      document = source_document(values, content, parsed.fetch("language"))
      capture_id = KnowledgeExtraction::Support.deterministic_ulid(
        "capture", document.captured_at || @clock.call, document.source_id, document.content_hash
      )
      evidence_id = KnowledgeExtraction::Support.stable_id(
        "evidence", document.source_id, document.content_hash, "capture"
      )
      attributes = @registry.enrich(
        "kind" => parsed.fetch("kind"), "title" => parsed.fetch("title"),
        "importance" => values.fetch("importance", "normal"),
        "topics" => @registry.topics(parsed.fetch("body")), "tags" => [],
        "language" => parsed.fetch("language"),
        "sensitivity" => values.fetch("sensitivity", "private")
      )
      create_intent = KnowledgeGraph::CreateCapture.new(
        capture_id: capture_id, kind: parsed.fetch("kind"), title: parsed.fetch("title"),
        body: parsed.fetch("body"), captured_at: document.captured_at&.iso8601,
        created_by: values["sender"] || "agent", importance: attributes.fetch("importance", "normal"),
        topics: attributes.fetch("topics", []), tags: attributes.fetch("tags", []),
        language: attributes.fetch("language", parsed.fetch("language")), evidence: [evidence_id],
        source: values.fetch("origin_source", values.fetch("source_type", "chat")),
        sensitivity: attributes.fetch("sensitivity", values.fetch("sensitivity", "private")),
        intent_id: KnowledgeExtraction::Support.stable_id("intent", capture_id, "create")
      )
      create_planned_id = KnowledgeExtraction::Support.stable_id("planned", capture_id, "create")
      specs = [{ planned_intent_id: create_planned_id, intent: create_intent, risk: "medium" }]
      candidates = Linker.new(vault_root: @vault_root, registry: @registry).candidates(parsed.fetch("body"))
      unless candidates.empty?
        categories = candidates.each_with_object({ "entity" => [], "project" => [], "contact" => [] }) do |candidate, result|
          result.fetch(candidate.category) << candidate.entity_id
        end
        specs << {
          planned_intent_id: KnowledgeExtraction::Support.stable_id("planned", capture_id, "link"),
          intent: KnowledgeGraph::LinkCapture.new(
            capture_id: capture_id, related_entities: categories.fetch("entity"),
            related_projects: categories.fetch("project"), related_contacts: categories.fetch("contact"),
            intent_id: KnowledgeExtraction::Support.stable_id("intent", capture_id, "link")
          ),
          dependencies: [create_planned_id], risk: "medium"
        }
      end
      proposal, planned = @factory.persist(
        document: document, planned_intents: specs,
        summary: "Capture a #{parsed.fetch('kind')} in the Knowledge Inbox",
        model_metadata: {
          "provider" => "capture-intent-classifier", "intent" => "knowledge.capture",
          "confidence" => parsed.fetch("confidence"),
          "link_candidates" => candidates.map(&:to_h),
          "plugins" => @registry.all.map { |plugin| plugin.name.to_s }
        },
        confidence: parsed.fetch("confidence")
      )
      {
        "status" => proposal.fetch("status"), "proposal_id" => proposal.fetch("proposal_id"),
        "intent" => "knowledge.capture", "kind" => parsed.fetch("kind"),
        "title" => parsed.fetch("title"), "candidate_links" => candidates.map do |candidate|
          candidate.to_h.reject { |key, _value| key == "entity_id" }
        end,
        "planned_intent_count" => planned.length, "approval_required" => true,
        "executable" => false,
        "confirmation" => confirmation(parsed.fetch("kind"), candidates)
      }
    rescue KeyError => error
      raise InvalidCapture, "capture request is missing #{error.key}"
    end

    private

    def source_document(values, content, language)
      metadata = {
        "observation_id" => values["observation_id"],
        "observation_source" => values["origin_source"],
        "conversation_id" => values["conversation_id"], "message_id" => values["message_id"],
        "sensitivity" => values.fetch("sensitivity", "private")
      }.reject { |_key, value| value.nil? }
      KnowledgeExtraction::SourceDocument.new(
        source_type: values.fetch("source_type", "chat"), content: content,
        language: values.fetch("language", language), captured_at: values["captured_at"] || @clock.call,
        source_uri: values["source_uri"], external_id: values["external_id"],
        title: values["title"], author: values["sender"], metadata: metadata
      )
    end

    def confirmation(kind, candidates)
      label = kind[0].upcase + kind[1..-1]
      article = label.match?(/\A[AEIOU]/) ? "an" : "a"
      return "I recognised this as #{article} #{label}. Review and approve the proposal to save it." if candidates.empty?

      links = candidates.map { |candidate| "#{candidate.name} (#{candidate.category})" }.join(", ")
      "I recognised this as #{article} #{label}. Candidate links: #{links}. Review and approve the exact proposal to save it."
    end
  end

  class PromotionProposalBuilder
    TARGET_KINDS = %w[project goal decision entity dataset relationship meeting].freeze

    def initialize(vault_root:, proposal_store: nil, event_bus: nil, clock: nil,
                   registry: KnowledgeCapture.registry)
      @vault_root = vault_root
      @clock = clock || -> { Time.now }
      @registry = registry
      @factory = ProposalFactory.new(
        vault_root: vault_root, proposal_store: proposal_store, event_bus: event_bus, clock: @clock
      )
    end

    def create(capture:, target_kind:, target_ids: [], attributes: {}, entity_type: nil)
      kind = target_kind.to_s
      raise PromotionError, "unsupported promotion target #{kind.inspect}" unless TARGET_KINDS.include?(kind)
      options = {
        "target_ids" => Array(target_ids), "attributes" => attributes,
        "entity_type" => entity_type
      }
      target_intents = @registry.promotion_intents(capture, kind, options)
      target_intents ||= built_in_targets(capture, kind, options)
      target_ids = Array(options["resolved_target_ids"] || target_ids).map(&:to_s)
      if target_ids.empty?
        target_ids = target_intents.flat_map { |intent| inferred_target_ids(intent) }.compact
      end
      raise PromotionError, "promotion target ID could not be determined" if target_ids.empty?

      document = KnowledgeExtraction::SourceDocument.new(
        source_type: "text", content: capture.body, language: capture.language,
        captured_at: @clock.call, external_id: "promotion:#{capture.id}:#{kind}",
        source_uri: "capture:#{capture.id}", title: capture.title,
        metadata: { "capture_id" => capture.id, "sensitivity" => capture.sensitivity }
      )
      specs = []
      dependencies = []
      target_intents.each_with_index do |intent, index|
        planned_id = KnowledgeExtraction::Support.stable_id(
          "planned", capture.id, "promote-target", kind, index
        )
        specs << { planned_intent_id: planned_id, intent: intent, risk: "medium" }
        dependencies << planned_id
      end
      specs << {
        planned_intent_id: KnowledgeExtraction::Support.stable_id("planned", capture.id, "promote", kind),
        intent: KnowledgeGraph::PromoteCapture.new(
          capture_id: capture.id, target_kind: kind, target_ids: target_ids,
          intent_id: KnowledgeExtraction::Support.stable_id("intent", capture.id, "promote", kind)
        ), dependencies: dependencies, risk: "high"
      }
      proposal, planned = @factory.persist(
        document: document, planned_intents: specs,
        summary: "Promote Capture #{capture.title.inspect} to #{kind}",
        model_metadata: {
          "provider" => "capture-promotion", "intent" => "knowledge.capture.promote",
          "capture_id" => capture.id, "target_kind" => kind, "target_ids" => target_ids
        }, confidence: 1.0
      )
      {
        "status" => proposal.fetch("status"), "proposal_id" => proposal.fetch("proposal_id"),
        "intent" => "knowledge.capture.promote", "target_kind" => kind,
        "planned_intent_count" => planned.length, "approval_required" => true,
        "executable" => false
      }
    end

    private

    def built_in_targets(capture, kind, options)
      existing = Array(options.fetch("target_ids"))
      return [] unless existing.empty?

      attrs = options.fetch("attributes").transform_keys(&:to_s)
      case kind
      when "project", "goal", "decision", "entity"
        entity_type = options["entity_type"] || (kind == "entity" ? nil : kind)
        raise PromotionError, "--entity-type is required for entity promotion" unless entity_type
        prefix = schema_prefix(entity_type)
        target_id = deterministic_id(prefix, capture, kind)
        attrs = { "id" => target_id, "name" => capture.title }.merge(attrs)
        attrs["project_status"] ||= "planned" if entity_type == "project"
        options["resolved_target_ids"] = [target_id]
        [KnowledgeGraph::CreateEntity.new(
          entity_type: entity_type, attributes: attrs, body: capture.body,
          intent_id: KnowledgeExtraction::Support.stable_id("intent", capture.id, "target", kind)
        )]
      when "meeting"
        target_id = deterministic_id("interaction", capture, kind)
        attrs = { "id" => target_id, "name" => capture.title }.merge(attrs)
        options["resolved_target_ids"] = [target_id]
        [KnowledgeGraph::CreateMeeting.new(
          attributes: attrs, body: capture.body,
          intent_id: KnowledgeExtraction::Support.stable_id("intent", capture.id, "target", kind)
        )]
      when "relationship"
        source = attrs.fetch("source")
        predicate = attrs.fetch("predicate")
        target = attrs.fetch("target")
        options["resolved_target_ids"] = ["relationship:#{source}:#{predicate}:#{target}"]
        [KnowledgeGraph::AddRelationship.new(
          source: source, predicate: predicate, target: target,
          attributes: attrs.fetch("attributes", {}),
          intent_id: KnowledgeExtraction::Support.stable_id("intent", capture.id, "target", kind)
        )]
      when "dataset"
        dataset_id = attrs["dataset_id"] || deterministic_id("dataset", capture, kind)
        options["resolved_target_ids"] = [dataset_id]
        [KnowledgeGraph::CreateDataset.new(
          dataset_id: dataset_id, dataset: attrs.fetch("dataset"), schema: attrs.fetch("schema"),
          owner_id: attrs["owner_id"], source: "capture-promotion",
          intent_id: KnowledgeExtraction::Support.stable_id("intent", capture.id, "target", kind)
        )]
      else []
      end
    rescue KeyError => error
      raise PromotionError, "#{kind} promotion requires attribute #{error.key}"
    end

    def schema_prefix(entity_type)
      KnowledgeGraph::SchemaRegistry.new(vault_root: @vault_root).fetch(entity_type).id_prefix
    rescue KnowledgeGraph::SchemaError
      entity_type.to_s.tr("_", "-")
    end

    def deterministic_id(prefix, capture, purpose)
      KnowledgeExtraction::Support.deterministic_ulid(prefix, @clock.call, capture.id, purpose)
    end

    def inferred_target_ids(intent)
      return [intent.attributes["id"] || intent.attributes[:id]] if intent.respond_to?(:attributes)
      return [intent.dataset_id] if intent.respond_to?(:dataset_id)

      []
    end
  end
end
