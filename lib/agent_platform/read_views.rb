# frozen_string_literal: true

require "digest"
require "json"

module AgentPlatform
  # Typed read models shared by thin transports. No Engine, proposal writer,
  # mutable Dataset adapter or persistent projection cache is constructed here.
  class ReadViews
    IDS = /\A[a-z][a-z0-9-]*_[0-9A-HJKMNP-TV-Z]{26}\z/.freeze
    WIKI = /!?\[\[([^\]]+)\]\]/.freeze
    ENTITY_FIELDS = %w[id type name aliases record_status is_self emails phones].freeze
    STRUCTURAL = %w[relationship interaction introduction].freeze

    def initialize(services, context)
      @services, @context, @agent = services, context, context.agent
    end

    def call(operation, arguments)
      @args = arguments
      if operation == :activity && !@agent.permits?("graph:read") && !@agent.permits?("capture:read")
        return unavailable("not_available")
      end
      return unavailable("source_bound_reached") unless within_read_budget?
      @date = @services.parse_date(arguments["as_of"])
      send(operation)
    rescue KnowledgeCapture::Error, ArgumentError
      raise InvalidArguments, "invalid typed read arguments"
    end

    def self.register(registry, services)
      {
        "kg.contacts.list" => :contacts, "kg.contacts.get" => :contact,
        "kg.contacts.top" => :top, "kg.contacts.relations" => :relations,
        "kg.captures.list" => :captures, "kg.captures.get" => :capture,
        "kg.activity.list" => :activity
      }.each do |id, operation|
        registry.register(id) do |arguments, context|
          result = new(services, context).call(operation, arguments)
          HandlerResult.new(payload: result, why: "Computed a bounded policy-visible typed read without canonical writes.")
        end
      end
    end

    private

    def within_read_budget?
      root = @services.vault_root
      paths = Dir.glob(File.join(root, "**/*.md")) + Dir.glob(File.join(root, KnowledgeSDK::RUNTIME_PATH, "**/*.{json,jsonl}"))
      paths.length <= 50_000 && paths.sum { |path| File.size(path) } <= 32 * 1024 * 1024
    end

    def raw_snapshot
      @raw_snapshot ||= @services.snapshot(@context)
    end

    def visible?(record)
      record && @agent.permits?("graph:read") && @services.visible_entity?(record, @agent)
    end

    def snapshot
      return @snapshot if @snapshot
      candidates = raw_snapshot.records(active_only: false).select { |record| visible?(record) }
      # Remove structural records with any hidden/missing endpoint before deriving
      # interactions, graph paths or scores. Iterate for structural dependencies.
      loop do
        ids = candidates.each_with_object({}) { |record, all| all[record.id] = true }
        selected = candidates.reject do |record|
          STRUCTURAL.include?(record.type) && reference_ids(record).any? { |id| !ids[id] }
        end
        break if selected.length == candidates.length
        candidates = selected
      end
      @snapshot = KnowledgeIntelligence::GraphSnapshot.new(candidates)
    end

    def reference_ids(record)
      direct = %w[subject_id object_id introducer_id person_a_id person_b_id].map { |key| record[key] }.compact
      links = record.data.values.flatten.grep(String).flat_map do |value|
        value.scan(WIKI).flatten.map { |target| raw_snapshot.resolve_link("[[#{target}]]") || "missing" }
      end
      (direct + links).uniq
    end

    def normalize(value)
      value.to_s.unicode_normalize(:nfc).downcase.tr("ё", "е")
    end

    def text(value, limit = 200)
      projected = value.to_s.gsub(WIKI) do
        id = raw_snapshot.resolve_link("[[#{Regexp.last_match(1)}]]")
        record = id && snapshot.record(id)
        record ? record.name.to_s : ""
      end
      projected.gsub(/[a-z][a-z0-9-]*_[0-9A-HJKMNP-TV-Z]{26}/) do |id|
        snapshot.record(id) ? id : ""
      end[0, limit]
    end

    def entity(record)
      name = record.name
      if name.to_s.empty? && record.type == "relationship"
        source, target = snapshot.record(record["subject_id"]), snapshot.record(record["object_id"])
        name = "#{source&.name} #{record['predicate'].to_s.tr('_', ' ')} #{target&.name}"
      end
      result = { "id" => record.id, "type" => record.type, "name" => text(name.to_s.empty? ? record.id : name),
        "aliases" => Array(record["aliases"]).first(50).map { |item| text(item) },
        "record_status" => record["record_status"].to_s }
      if @agent.permits?("graph:private")
        result["emails"] = Array(record["emails"]).first(20).map { |item| text(item) }
        result["phones"] = Array(record["phones"]).first(20).map { |item| text(item) }
      end
      result
    end

    def supported_contacts?
      registry = KnowledgeGraph::SchemaRegistry.new(vault_root: @services.vault_root)
      registry.key?("person") && registry.fetch("person").name_required? &&
        (%w[tier sensitivity data_origin] - registry.fetch("person").required_fields).empty?
    end

    def people
      snapshot.records(type: "person")
    end

    def require_contact
      record = snapshot.record(@args.fetch("entity_id"))
      raise PolicyDenied, "record not found" unless record && record.type == "person" && record.active?
      record
    end

    def contacts
      return unavailable("contact_schema_unsupported") unless supported_contacts?
      needle = normalize(@args["query"])
      items = people.map { |record| entity(record) }.select do |item|
        needle.empty? || [item["id"], item["name"], *item["aliases"]].any? { |value| normalize(value).include?(needle) }
      end.sort_by { |item| [normalize(item["name"]), item["id"]] }
      list(items, items.map { |item| [normalize(item["name"]), item["id"]] })
    end

    def contact
      record = require_contact
      item = entity(record)
      if @agent.permits?("intelligence:read")
        signals = ranking(record)
        item["interaction"] = signals
        strength = feature_engine.fetch("relationship_strength", subject_id: record.id)
        known = signals["score"] || !snapshot.relationships(as_of: @date, entity_id: record.id).empty?
        item["relationship_strength"] = { "version" => strength.version, "score" => known ? strength.value : nil,
          "explanation" => known ? text(strength.explanation, 500) : "No visible interaction or relationship signals." }
      end
      result({ "item" => item }, dependencies: item)
    end

    def feature_engine
      @features ||= KnowledgeIntelligence::FeatureEngine.new(snapshot: snapshot,
        registry: KnowledgeIntelligence::DefaultFeatures.registry, as_of: @date)
    end

    def ranking(record)
      recency = feature_engine.fetch("recency_score", subject_id: record.id, params: { "half_life_days" => 90 })
      frequency = feature_engine.fetch("interaction_frequency", subject_id: record.id, params: { "window_days" => 365 })
      references = (recency.evidence + frequency.evidence).map(&:record_id).uniq.sort
      count = frequency.metadata.fetch("interaction_count", 0)
      # No observed substantive date is unknown recency, never zero importance.
      latest_record = snapshot.record(recency.metadata["latest_interaction_id"])
      latest = latest_record && snapshot.parse_time(latest_record["starts_at"])&.iso8601
      has_signal = !recency.evidence.empty? || count > 0
      { "formula" => "interaction-v1", "score" => has_signal ? (0.6 * recency.value + 0.4 * frequency.value).round(6) : nil,
        "recency_score" => has_signal ? recency.value.round(6) : nil,
        "interaction_frequency" => has_signal ? frequency.value.round(6) : nil,
        "interaction_count" => has_signal ? count : nil, "latest_at" => latest,
        "reasons" => has_signal ? [text(recency.explanation, 500), text(frequency.explanation, 500)] : ["No visible recorded interaction signals."],
        "evidence" => references.first(20).map { |id| { "record_id" => id, "role" => "interaction" } } }
    end

    def top
      return unavailable("contact_schema_unsupported") unless supported_contacts?
      items = people.reject { |person| person.id == snapshot.self_id }.map do |person|
        entity(person).merge("interaction" => ranking(person))
      end.select { |item| item.dig("interaction", "score") }
      items.sort_by! { |item| [-item.dig("interaction", "score"), item["id"]] }
      return unavailable("interaction_signals_missing") if items.empty?
      result({ "items" => items.first(10), "formula" => "interaction-v1", "self_id" => snapshot.self_id },
        dependencies: items, limitations: items.length < 10 ? ["fewer_than_ten_signaled_contacts"] : [])
    end

    def relations
      root = require_contact
      depth = @args.fetch("depth", 1)
      graph = KnowledgeIntelligence::Projection.knowledge(snapshot, as_of: @date)
      distances, edges, frontier = { root.id => 0 }, {}, [root.id]
      bounded = false
      depth.times do |level|
        following = []
        frontier.sort.each do |id|
          graph.neighbors(id).each do |neighbor|
            if !distances.key?(neighbor) && distances.length >= 100
              bounded = true; next
            end
            graph.edge_ids(id, neighbor).each do |edge_id|
              if !edges.key?(edge_id) && edges.length >= 200
                bounded = true; next
              end
              edge = graph.edge_records.fetch(edge_id)
              edges[edge_id] = { "id" => edge_id, "source" => edge["source"], "target" => edge["target"],
                "predicate" => text(edge["kind"]), "direction" => edge["source"] == id ? "outgoing" : "incoming", "depth" => level + 1 }
            end
            next if distances.key?(neighbor) || !edges.values.any? { |edge| [edge["source"], edge["target"]].include?(neighbor) }
            distances[neighbor] = level + 1; following << neighbor
          end
        end
        frontier = following
      end
      nodes = distances.sort_by { |id, level| [level, id] }.map { |id, level| entity(snapshot.fetch(id)).merge("depth" => level) }
      ordered = edges.values.sort_by { |edge| [edge["depth"], edge["target"], edge["id"]] }
      result({ "nodes" => nodes, "edges" => ordered }, dependencies: [nodes, ordered], limitations: bounded ? ["result_bound_reached"] : [])
    end

    def list(items, keys, limitations: [])
      after = @args["after"]
      raise InvalidArguments, "invalid after key" if after && !keys.include?(after)
      start = after ? keys.index(after) + 1 : 0
      limit = @args.fetch("limit", 25)
      selected = items.slice(start, limit) || []
      more = start + selected.length < items.length
      result({ "items" => selected, "page" => { "returned" => selected.length, "after" => more ? keys[start + selected.length - 1] : nil } },
        dependencies: items, limitations: limitations, empty: selected.empty?)
    end

    def result(data, dependencies:, limitations: [], empty: false, evidence: [])
      { "status" => limitations.empty? ? (empty ? "empty" : "ok") : "partial", "data" => data,
        "limitations" => limitations, "evidence" => evidence.first(20),
        "source_version" => Digest::SHA256.hexdigest(Value.canonical_json([dependencies, limitations])) }
    end

    def unavailable(code)
      { "status" => "unavailable", "data" => nil, "limitations" => [code], "evidence" => [],
        "source_version" => Digest::SHA256.hexdigest(code) }
    end
  end
end
