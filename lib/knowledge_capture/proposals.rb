# frozen_string_literal: true

require "digest"

module KnowledgeCapture
  class ProposalFactory
    def initialize(vault_root:, proposal_store: nil, event_bus: nil, clock: nil)
      @vault_root = vault_root
      @clock = clock || -> { Time.now }
      @store = proposal_store || KnowledgeExtraction::ProposalStore.new(vault_root: vault_root, clock: @clock)
      @event_bus = event_bus
    end

    def evidence_id(document, role: "capture")
      KnowledgeExtraction::Support.stable_id(
        "evidence", document.source_id, document.content_hash, role
      )
    end

    def persist(document:, planned_intents:, summary:, model_metadata:, confidence:,
                evidence_documents: [])
      proposal_id = KnowledgeExtraction::Support.stable_id(
        "proposal", document.source_id, summary,
        KnowledgeExtraction::Support.canonical_json(
          planned_intents.map { |spec| spec.fetch(:intent).to_h }
        )
      )
      sources = [{ document: document, role: "capture" }] + Array(evidence_documents)
      evidence = sources.map do |spec|
        source_document = spec.fetch(:document)
        excerpt = source_document.content[0, 2_000]
        {
          "evidence_id" => evidence_id(source_document, role: spec.fetch(:role)),
          "source_id" => source_document.source_id, "start_offset" => 0,
          "end_offset" => excerpt.length, "excerpt" => excerpt
        }
      end
      evidence_ids = evidence.map { |item| item.fetch("evidence_id") }
      fact_id = KnowledgeExtraction::Support.stable_id("fact", document.source_id, "capture")
      planned = planned_intents.map do |spec|
        KnowledgeExtraction::PlannedIntent.new(
          planned_intent_id: spec.fetch(:planned_intent_id), intent: spec.fetch(:intent),
          fact_ids: [fact_id], evidence_ids: evidence_ids,
          planning_confidence: confidence, risk: spec.fetch(:risk, "medium"),
          approval_requirement: "human_review", dependencies: spec.fetch(:dependencies, []),
          blocked_reasons: [], provenance: {
            source_id: document.source_id, source_type: document.source_type,
            captured_at: document.captured_at&.iso8601
          }
        )
      end
      proposal = {
        "proposal_id" => proposal_id, "source" => stringify(document.metadata_only),
        "summary" => summary,
        "facts" => [{
          "fact_id" => fact_id, "fact_type" => "capture", "confidence" => confidence,
          "evidence" => evidence
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
        "prompt_version" => "knowledge-capture-v2", "pipeline_version" => KnowledgeSDK::VERSION,
        "created_at" => (@clock.call).iso8601, "status" => "awaiting_approval",
        "ingestion_state" => @store.classify_source(document), "metrics" => {
          "proposed_intents" => planned.length, "capture_evidence" => evidence.length
        }
      }
      @store.save(proposal)
      sources.each { |spec| @store.record_source(spec.fetch(:document), proposal_id) }
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
                   registry: KnowledgeCapture.registry, bookmark_fetcher: nil,
                   url_normalizer: Bookmarks::UrlNormalizer.new)
      @vault_root = vault_root
      @clock = clock || -> { Time.now }
      @registry = registry
      @url_normalizer = url_normalizer
      @bookmark_fetcher = bookmark_fetcher || Bookmarks::WebMetadataFetcher.new(
        normalizer: @url_normalizer
      )
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
      if parsed.fetch("kind") == "bookmark" && parsed["normalized_url"]
        return BookmarkProposalBuilder.new(
          vault_root: @vault_root, factory: @factory, registry: @registry,
          clock: @clock, fetcher: @bookmark_fetcher, normalizer: @url_normalizer
        ).create(values: values, parsed: parsed, document: document)
      end
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
        "executable" => false, "duplicate_candidate" => false,
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

  class BookmarkProposalBuilder
    def initialize(vault_root:, factory:, registry:, clock:, fetcher:, normalizer:)
      @vault_root = vault_root
      @factory = factory
      @registry = registry
      @clock = clock
      @fetcher = fetcher
      @normalizer = normalizer
      @duplicates = Bookmarks::DuplicateDetector.new(
        vault_root: vault_root, normalizer: normalizer
      )
    end

    def create(values:, parsed:, document:)
      normalized_url = parsed.fetch("normalized_url")
      duplicate = @duplicates.find(url: normalized_url)
      return duplicate_result(parsed, duplicate, normalized_url) if duplicate

      fetched = fetch_metadata(values, normalized_url)
      canonical_url = @normalizer.normalize(
        fetched["canonical_url"] || fetched["final_url"] || normalized_url
      )
      resource_type = Bookmarks::ResourceClassifier.new.classify(
        text: document.content, url: canonical_url, metadata: fetched
      )
      resource_type = parsed.fetch("resource_type") if resource_type == "unknown"
      topics = bookmark_topics(parsed, fetched, resource_type)
      attributes = @registry.enrich(
        {
          "kind" => "bookmark", "title" => fetched["title"] || parsed.fetch("title"),
          "importance" => values.fetch("importance", "normal"), "topics" => topics,
          "tags" => [], "language" => parsed.fetch("language"),
          "sensitivity" => values.fetch("sensitivity", "private"),
          "resource_type" => resource_type, "collections" => parsed.fetch("collections", [])
        }
      )
      resource_type = attributes.fetch("resource_type", resource_type).to_s
      unless Bookmarks::RESOURCE_TYPES.include?(resource_type)
        raise InvalidCapture, "capture enricher returned unsupported bookmark resource type"
      end
      title = attributes.fetch("title", fetched["title"] || parsed.fetch("title")).to_s.strip
      title = parsed.fetch("title") if title.empty?
      content_hash = fetched["content_hash"]
      duplicate = @duplicates.find(
        url: normalized_url, canonical_url: canonical_url, content_hash: content_hash
      )
      return duplicate_result(parsed, duplicate, normalized_url, canonical_url: canonical_url,
                              resource_type: resource_type) if duplicate

      page_document = page_evidence_document(fetched, canonical_url)
      evidence_ids = [@factory.evidence_id(document)]
      evidence_documents = []
      if page_document
        evidence_ids << @factory.evidence_id(page_document, role: "bookmark-page")
        evidence_documents << { document: page_document, role: "bookmark-page" }
      end
      capture_id = KnowledgeExtraction::Support.deterministic_ulid(
        "capture", document.captured_at || @clock.call, document.source_id, document.content_hash
      )
      create_intent = KnowledgeGraph::CreateCapture.new(
        capture_id: capture_id, kind: "bookmark", title: title,
        body: parsed.fetch("body"), captured_at: document.captured_at&.iso8601,
        created_by: values["sender"] || "agent",
        importance: attributes.fetch("importance", "normal"),
        topics: Array(attributes.fetch("topics", topics)).map(&:to_s).reject(&:empty?).uniq.sort,
        tags: Array(attributes.fetch("tags", [])).map(&:to_s),
        language: attributes.fetch("language", parsed.fetch("language")), evidence: evidence_ids,
        source: values.fetch("origin_source", values.fetch("source_type", "chat")),
        sensitivity: values.fetch("sensitivity", "private"),
        url: normalized_url, canonical_url: canonical_url,
        domain: @normalizer.domain(canonical_url), resource_type: resource_type,
        user_note: blank_to_nil(parsed.fetch("user_note", "")),
        collections: Array(attributes.fetch("collections", parsed.fetch("collections", []))),
        author_name: fetched["author_name"], published_at: fetched["published_at"],
        description: fetched["description"], content_excerpt: fetched["content_excerpt"],
        content_hash: content_hash, fetch_status: fetched.fetch("status"),
        fetched_at: fetched["fetched_at"], page_language: fetched["page_language"],
        reading_status: "unread",
        intent_id: KnowledgeExtraction::Support.stable_id("intent", capture_id, "create")
      )
      create_planned_id = KnowledgeExtraction::Support.stable_id("planned", capture_id, "create")
      specs = [{ planned_intent_id: create_planned_id, intent: create_intent, risk: "medium" }]
      candidates = link_candidates(parsed, fetched)
      add_link_spec(specs, candidates, capture_id, create_planned_id)
      proposal, planned = @factory.persist(
        document: document, planned_intents: specs, evidence_documents: evidence_documents,
        summary: "Save a web bookmark in the Knowledge Inbox",
        model_metadata: {
          "provider" => "bookmark-metadata", "intent" => "knowledge.capture.bookmark",
          "confidence" => parsed.fetch("confidence"), "normalized_url" => normalized_url,
          "canonical_url" => canonical_url, "resource_type" => resource_type,
          "fetch_status" => fetched.fetch("status"),
          "link_candidates" => candidates.map(&:to_h),
          "plugins" => @registry.all.map { |plugin| plugin.name.to_s }
        }, confidence: parsed.fetch("confidence")
      )
      result(parsed, planned, proposal, candidates, create_intent)
    end

    private

    def fetch_metadata(values, normalized_url)
      return { "status" => "not_attempted" } if values["fetch_metadata"] == false

      fetched = @fetcher.fetch(normalized_url)
      unless fetched.is_a?(Hash) && Bookmarks::FETCH_STATUSES.include?(fetched["status"])
        raise InvalidCapture, "bookmark fetcher returned an invalid result"
      end
      fetched = fetched.transform_keys(&:to_s)
      fetched["fetched_at"] ||= @clock.call.iso8601 unless fetched["status"] == "not_attempted"
      fetched
    rescue Bookmarks::FetchError, Timeout::Error, SocketError, SystemCallError => error
      {
        "status" => "failed", "fetched_at" => @clock.call.iso8601,
        "fetch_error" => error.class.name.split("::").last
      }
    end

    def bookmark_topics(parsed, fetched, resource_type)
      source = [
        parsed.fetch("user_note", ""), fetched["title"], fetched["description"],
        fetched["content_excerpt"]
      ].compact.join(" ")
      built_in = Bookmarks::TopicClassifier.new.classify(source, resource_type: resource_type)
      (Array(parsed["topics"]) + built_in + @registry.topics(source)).map(&:to_s)
                                                                  .reject(&:empty?).uniq.sort
    end

    def page_evidence_document(fetched, canonical_url)
      return nil unless fetched["status"] == "succeeded"
      excerpt = fetched["content_excerpt"].to_s.strip
      return nil if excerpt.empty?

      KnowledgeExtraction::SourceDocument.new(
        source_type: "text", content: excerpt,
        language: fetched["page_language"] || "und", captured_at: fetched["fetched_at"],
        source_uri: canonical_url,
        external_id: "bookmark-page:#{Digest::SHA256.hexdigest(canonical_url)}:#{fetched['content_hash']}",
        title: fetched["title"], author: fetched["author_name"],
        metadata: {
          "untrusted_web_content" => true, "fetch_status" => "succeeded",
          "canonical_url" => canonical_url, "final_url" => fetched["final_url"],
          "content_type" => fetched["content_type"], "fetched_at" => fetched["fetched_at"]
        }.reject { |_key, value| value.nil? }
      )
    end

    def link_candidates(parsed, fetched)
      text = [parsed.fetch("body"), fetched["title"], fetched["author_name"]].compact.join(" ")
      Linker.new(vault_root: @vault_root, registry: @registry).candidates(text)
    end

    def add_link_spec(specs, candidates, capture_id, create_planned_id)
      return if candidates.empty?

      categories = candidates.each_with_object({ "entity" => [], "project" => [], "contact" => [] }) do |candidate, grouped|
        grouped.fetch(candidate.category) << candidate.entity_id
      end
      specs << {
        planned_intent_id: KnowledgeExtraction::Support.stable_id("planned", capture_id, "link"),
        intent: KnowledgeGraph::LinkCapture.new(
          capture_id: capture_id, related_entities: categories.fetch("entity"),
          related_projects: categories.fetch("project"), related_contacts: categories.fetch("contact"),
          intent_id: KnowledgeExtraction::Support.stable_id("intent", capture_id, "link")
        ), dependencies: [create_planned_id], risk: "medium"
      }
    end

    def result(parsed, planned, proposal, candidates, intent)
      {
        "status" => proposal.fetch("status"), "proposal_id" => proposal.fetch("proposal_id"),
        "intent" => "knowledge.capture.bookmark", "kind" => "bookmark",
        "title" => intent.title, "candidate_links" => candidates.map do |candidate|
          candidate.to_h.reject { |key, _value| key == "entity_id" }
        end,
        "planned_intent_count" => planned.length, "approval_required" => true,
        "executable" => false, "normalized_url" => intent.url,
        "canonical_url" => intent.canonical_url, "domain" => intent.domain,
        "resource_type" => intent.resource_type, "topics" => intent.topics,
        "collections" => intent.collections, "user_note" => intent.user_note.to_s,
        "fetch_status" => intent.fetch_status, "duplicate_candidate" => false,
        "confirmation" => confirmation(intent),
        "explainability" => explainability(
          intent.url, intent.resource_type, false, parsed.fetch("confidence")
        )
      }
    end

    def duplicate_result(parsed, duplicate, normalized_url, canonical_url: nil, resource_type: nil)
      capture = duplicate.fetch("capture")
      exact = duplicate.fetch("exact")
      canonical = canonical_url || capture.canonical_url || normalized_url
      classified_type = resource_type || capture.resource_type || "unknown"
      {
        "status" => exact ? "duplicate" : "duplicate_candidate",
        "intent" => "knowledge.capture.bookmark", "kind" => "bookmark",
        "title" => capture.title, "candidate_links" => [], "planned_intent_count" => 0,
        "approval_required" => false, "executable" => false,
        "normalized_url" => normalized_url,
        "canonical_url" => canonical,
        "domain" => capture.domain || @normalizer.domain(canonical),
        "resource_type" => classified_type,
        "topics" => capture.topics, "collections" => capture.collections,
        "user_note" => parsed.fetch("user_note", ""),
        "fetch_status" => capture.fetch_status || "not_attempted",
        "duplicate_candidate" => true, "duplicate_exact" => exact,
        "duplicate_reason" => duplicate.fetch("reason"),
        "existing_capture" => capture.public_h(include_body: false),
        "confirmation" => duplicate_confirmation(capture, parsed.fetch("language"), exact),
        "explainability" => explainability(
          normalized_url, classified_type, true, parsed.fetch("confidence")
        )
      }
    end

    def explainability(url, resource_type, duplicate, confidence)
      {
        "intent" => "knowledge.capture.bookmark", "route" => "capture",
        "resource_type" => resource_type || "unknown", "normalized_url" => url,
        "duplicate_candidate" => duplicate, "confidence" => confidence
      }
    end

    def confirmation(intent)
      topics = intent.topics.empty? ? "—" : intent.topics.join(", ")
      note = intent.user_note.to_s.empty? ? "—" : "\"#{intent.user_note}\""
      case intent.language
      when "ru"
        "#{intent.title}\n#{intent.domain}\n\nТемы:\n#{topics}\n\nЗаметка:\n#{note}\n\nСохранить? Подтвердите точное предложение."
      when "el"
        "#{intent.title}\n#{intent.domain}\n\nΘέματα:\n#{topics}\n\nΣημείωση:\n#{note}\n\nΑποθήκευση; Εγκρίνετε την ακριβή πρόταση."
      else
        "#{intent.title}\n#{intent.domain}\n\nTopics:\n#{topics}\n\nNote:\n#{note}\n\nSave it? Approve the exact proposal."
      end
    end

    def duplicate_confirmation(capture, language, exact)
      date = capture.captured_at.strftime("%Y-%m-%d")
      case language
      when "ru"
        "Эта страница #{exact ? 'уже сохранена' : 'похожа на сохранённую'} #{date}. Добавить новую заметку к существующей записи?"
      when "el"
        "Αυτή η σελίδα #{exact ? 'έχει ήδη αποθηκευτεί' : 'μοιάζει με αποθηκευμένη σελίδα'} στις #{date}. Να προστεθεί νέα σημείωση στην υπάρχουσα εγγραφή;"
      else
        "This page #{exact ? 'was already saved' : 'looks like a saved page'} on #{date}. Add a new note to the existing record?"
      end
    end

    def blank_to_nil(value)
      string = value.to_s
      string.empty? ? nil : string
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
