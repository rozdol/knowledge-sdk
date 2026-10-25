# frozen_string_literal: true

module AgentPlatform
  class ReadViews
    # Only this small method set reaches the Activity projection. Deletions and
    # historical row changes cannot prove current row provenance, so row activities
    # are deliberately omitted with a source-level coverage limitation.
    class ActivityReadSource
      def initialize(reader, allowed_ids)
        @reader, @allowed_ids = reader, allowed_ids
      end

      def activity_records
        @reader.activity_records.select do |item|
          @allowed_ids.include?(item["dataset_id"]) && item["row_id"].to_s.empty? && item["action"] == "create"
        end
      end
    end

    private

    def visible_captures
      @visible_captures ||= @services.capture_store(@context).all.select do |item|
        item.status != "deleted" && (item.sensitivity != "restricted" || @agent.permits?("capture:restricted"))
      end.map do |item|
        data = Value.mutable(item.data)
        %w[title topics tags user_note description content_excerpt author_name collections].each do |field|
          next unless data[field]
          data[field] = data[field].is_a?(Array) ? data[field].map { |value| text(value, 10_000) }.reject(&:empty?) : text(data[field], 10_000)
        end
        %w[related_entities related_contacts related_projects promoted_to].each do |field|
          data[field] = Array(data[field]).each_with_object([]) do |reference, ids|
            id = raw_snapshot.resolve_link(reference) || (reference.match?(IDS) && reference)
            ids << id if id && snapshot.record(id)
          end
        end
        KnowledgeCapture::ReadProjection.new(capture: item, data: data, body: rendition(item.body))
      end
    end

    def rendition(body)
      # Plain text only: remove attachment destinations, HTML tags and Markdown
      # wrappers. Imported script text is data and is never evaluated.
      text(body, body.length).gsub(/!?(\[([^\]]*)\])\([^)]*\)/, '\\2')
        .gsub(/<[^>]*>/, "").gsub(/^\s*(?:#+|>|[-*+]\s)\s?/, "").gsub(/[`*_~]/, "")
    end

    def capture_item(item, detail: false)
      links = %w[related_entities related_contacts related_projects promoted_to].flat_map { |key| Array(item.data[key]) }.uniq.sort
      value = { "id" => item.id, "kind" => item.kind, "title" => text(item.title), "status" => item.status,
        "captured_at" => item.captured_at.iso8601, "excerpt" => item.body[0, 500],
        "tags" => item.tags.first(50).map { |tag| text(tag) }, "topics" => item.topics.first(50).map { |topic| text(topic) },
        "links" => links.first(50) }
      if detail
        value["text"] = item.body[0, 10_000]
        value["text_truncated"] = item.body.length > 10_000
        value["bookmark"] = %w[domain resource_type author_name published_at description fetch_status reading_status].each_with_object({}) do |key, result|
          result[key] = text(item.data[key], key == "description" ? 500 : 200) if item.data[key]
        end
      end
      value
    end

    def capture_evidence(item)
      # Opaque references belonging to an authorized Capture; never dereference
      # local Evidence or trust a path/URI in imported metadata.
      item.evidence.grep(/\Aevidence_[0-9A-HJKMNP-TV-Z]{26}\z/).first(20).map do |id|
        { "record_id" => item.id, "evidence_id" => id, "role" => "capture_source" }
      end
    end

    def captures
      from, to = instant_window(default: false)
      matches = @services.capture_search(@context).typed_matches(captures: visible_captures,
        query: @args["query"], kind: @args["kind"], status: @args["status"], from: from, to: to)
      items = matches.map { |item, score| capture_item(item).merge("relevance" => score) }
      keys = matches.map { |item, score| [-score, -item.captured_at.to_f, item.id] }
      list(items, keys)
    end

    def capture
      item = visible_captures.find { |candidate| candidate.id == @args.fetch("capture_id") }
      raise PolicyDenied, "record not found" unless item
      public_item = capture_item(item, detail: true)
      evidence = capture_evidence(item)
      result({ "item" => public_item }, dependencies: [public_item, evidence], evidence: evidence,
        limitations: public_item["text_truncated"] ? ["text_truncated"] : [])
    end

    def instant_window(default: true)
      if @args["from"] || @args["to"]
        raise InvalidArguments, "both time boundaries are required" unless @args["from"] && @args["to"]
        values = %w[from to].map do |key|
          value = @args.fetch(key)
          raise InvalidArguments, "time requires an explicit offset" unless value.match?(/T.*(?:Z|[+-]\d\d:\d\d)\z/)
          Time.iso8601(value)
        end
        raise InvalidArguments, "invalid time window" unless values[1] > values[0] && values[1] - values[0] <= 367 * 86_400
        values
      elsif default
        [@services.clock.call - 30 * 86_400, @services.clock.call]
      else
        [nil, nil]
      end
    end

    def activity
      return unavailable("not_available") unless @agent.permits?("graph:read") || @agent.permits?("capture:read")
      from, to = instant_window
      warnings = []
      warnings << "graph_activity_not_available" unless @agent.permits?("graph:read")
      warnings << "capture_activity_not_available" unless @agent.permits?("capture:read")
      reader = @services.activity_reader(@context)
      dataset_ids = @agent.permits?("dataset:read") ? snapshot.records(type: "dataset").select do |item|
        (item["sensitivity"] != "restricted" || @agent.permits?("dataset:restricted")) &&
          audit_references(item.data).all? { |id| snapshot.record(id) }
      end.map(&:id) : []
      # A denied source reveals no storage state. For a permitted source, preserve
      # graph/Capture history even if Dataset storage is absent or outdated.
      dataset_source_allowed = @agent.permits?("dataset:read") && !dataset_ids.empty?
      source = dataset_source_allowed ? ActivityReadSource.new(reader, dataset_ids) : ActivityReadSource.new(EmptyActivitySource.new, [])
      timeline = KnowledgeActivity::Timeline.new(vault_root: @services.vault_root,
        clock: @services.clock, cache: false, dataset_reader: source,
        proposal_store: KnowledgeExtraction::ProposalReader.new(vault_root: @services.vault_root))
      projected = timeline.all
      warnings.concat(timeline.source_warnings) if dataset_source_allowed
      warnings << "dataset_row_history_not_projected" if dataset_source_allowed
      warnings << "dataset_activity_not_available" unless dataset_source_allowed
      capture_ids = @agent.permits?("capture:read") ? visible_captures.map(&:id) : []
      items = projected.each_with_object([]) do |item, result|
        next unless item.privacy == "visible" && Time.iso8601(item.created_at) >= from && Time.iso8601(item.created_at) < to
        ids = item.affected_objects.map { |object| object["id"] }
        # Unknown/deleted/recommendation provenance cannot authorize a projection.
        next if ids.empty? || ids.any? { |id| !snapshot.record(id) && !capture_ids.include?(id) }
        next if ids.any? { |id| snapshot.record(id)&.type == "dataset" && !dataset_ids.include?(id) }
        # The audit may refer to hidden endpoints that are absent from its object
        # list. Check typed ID/wiki references as well before projecting anything.
        references = audit_references(item.audit.dig("intent", "params") || {})
        next if references.any? { |id| !snapshot.record(id) && !capture_ids.include?(id) }
        objects = item.affected_objects.map do |object|
          id = object["id"]
          label = snapshot.record(id) ? entity(snapshot.record(id))["name"] : visible_captures.find { |candidate| candidate.id == id }.title
          { "id" => id, "type" => object["kind"].to_s, "name" => text(label) }
        end
        source_name = ids.all? { |id| capture_ids.include?(id) } ? "capture" : ids.any? { |id| dataset_ids.include?(id) } ? "dataset" : "graph"
        result << { "id" => item.id, "type" => item.type, "summary" => "#{objects.map { |object| object['name'] }.join(', ')} — #{item.type.tr('_', ' ')}."[0, 500],
          "created_at" => item.created_at, "source" => source_name, "objects" => objects.first(50) }
      end
      needle = normalize(@args["query"])
      items.select! { |item| normalize(JSON.generate(item)).include?(needle) } unless needle.empty?
      items.sort_by! { |item| [-Time.iso8601(item["created_at"]).to_f, item["id"]] }
      list(items, items.map { |item| [-Time.iso8601(item["created_at"]).to_f, item["id"]] }, limitations: warnings.uniq.sort)
    end

    class EmptyActivitySource
      def activity_records; []; end
    end

    def audit_references(value)
      case value
      when Hash then value.values.flat_map { |item| audit_references(item) }
      when Array then value.flat_map { |item| audit_references(item) }
      when String
        prefixes = @reference_prefixes ||= begin
          registry = KnowledgeGraph::SchemaRegistry.new(vault_root: @services.vault_root)
          registry.keys.map { |key| registry.fetch(key).id_prefix } + ["capture"]
        end
        ids = value.scan(/[a-z][a-z0-9-]*_[0-9A-HJKMNP-TV-Z]{26}/).select { |id| prefixes.include?(id.split("_", 2).first) }
        ids + value.scan(WIKI).flatten.map { |link| raw_snapshot.resolve_link("[[#{link}]]") || "missing" }
      else []
      end
    end
  end
end
