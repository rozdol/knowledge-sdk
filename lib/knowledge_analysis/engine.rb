# frozen_string_literal: true

require "date"
require "digest"
require "time"

module KnowledgeAnalysis
  class Engine
    CAPABILITY_ID = "kg.analysis.run".freeze
    CAPABILITY_VERSION = "1.0.0".freeze
    MAX_ROWS_PER_DATASET = 10_000

    def initialize(vault_root:, dataset_engine: nil, snapshot: nil, timeline: nil,
                   event_store: nil, event_bus: nil, cache: nil, registry: nil,
                   clock: nil)
      @vault_root = File.expand_path(vault_root.to_s)
      @clock = clock || -> { Time.now }
      @dataset_engine = dataset_engine || StructuredDataset::Engine.new(vault_root: @vault_root, clock: @clock)
      @snapshot = snapshot || KnowledgeIntelligence::GraphSnapshot.load(vault_root: @vault_root)
      @event_store = event_store || KnowledgeOrchestration::EventStore.new(vault_root: @vault_root)
      @event_bus = event_bus
      @cache = cache || KnowledgeOrchestration::KnowledgeCache.new(vault_root: @vault_root, clock: @clock)
      @timeline = timeline || KnowledgeActivity::Timeline.new(
        vault_root: @vault_root, event_store: @event_store, event_bus: @event_bus,
        cache: @cache, clock: @clock
      )
      @registry = registry || KnowledgeAnalysis.registry
    end

    def analyze(question, from: nil, to: nil, as_of: nil, propose_recommendations: false)
      query = question.to_s.strip
      raise InvalidAnalysis, "analysis question is required" if query.empty?

      date = parse_date(as_of || @clock.call)
      window = resolve_window(query, from, to, date)
      datasets = load_datasets
      signature = dataset_signature(datasets)
      arguments = {
        "question" => query, "from" => window.fetch("from")&.iso8601,
        "to" => window.fetch("to")&.iso8601, "as_of" => date.iso8601,
        "dataset_signature" => signature,
        "propose_recommendations" => !!propose_recommendations
      }
      cache_key = @cache.key(
        capability_id: CAPABILITY_ID, capability_version: CAPABILITY_VERSION,
        arguments: arguments, snapshot_digest: @snapshot.digest
      )
      unless propose_recommendations
        cached = @cache.fetch(cache_key, snapshot_digest: @snapshot.digest)
        return { "status" => "ok", "analysis" => cached.value } if cached
      end

      events = safe_events
      context = AnalysisContext.new(
        question: query, datasets: datasets, snapshot: @snapshot,
        activities: safe_activities, events: events,
        intelligence_findings: intelligence_findings(date),
        planning_signals: planning_signals,
        correlations: CorrelationEngine.new,
        from: window.fetch("from"), to: window.fetch("to"), as_of: date
      )
      plugins = @registry.all.select { |plugin| plugin.supports?(query, context) }
      domain_plugins = plugins.reject { |plugin| plugin.name == "generic" }
      plugins = domain_plugins unless domain_plugins.empty?
      fragments = plugins.map { |plugin| plugin.analyze(context) }
      analysis = aggregate(query, context, plugins, fragments, signature)
      if propose_recommendations && !analysis.fetch("recommendations").empty?
        proposal = RecommendationProposalBuilder.new(
          vault_root: @vault_root, event_bus: @event_bus, clock: @clock
        ).create(
          question: query, recommendations: analysis.fetch("recommendations"),
          analysis_digest: analysis.fetch("analysis_digest"), as_of: date
        )
        analysis["recommendations"] = analysis.fetch("recommendations").map do |item|
          item.merge("proposal_id" => proposal.fetch("proposal_id"))
        end
      end
      dependencies = KnowledgeOrchestration::ArtifactDependencies.new(
        event_ids: events.map(&:id),
        event_types: %w[DatasetChanged GraphChanged RecommendationGenerated],
        snapshot_digest: @snapshot.digest,
        entity_ids: analysis.fetch("graph_evidence").map { |item| item["record_id"] }.compact,
        capability_id: CAPABILITY_ID, capability_version: CAPABILITY_VERSION
      )
      @cache.write(
        artifact_type: "analysis", cache_key: cache_key, value: analysis,
        dependencies: dependencies,
        metadata: { "dataset_signature" => signature, "plugins" => plugins.map(&:name) }
      )
      { "status" => "ok", "analysis" => analysis }
    end

    private

    def load_datasets
      @dataset_engine.list.each_with_object({}) do |entry, result|
        next unless entry["storage_status"] == "ready"
        next if entry["sensitivity"] == "restricted"

        description = @dataset_engine.describe(entry.fetch("dataset_id"))
        temporal = description.fetch("columns").find do |column|
          %w[DATE DATETIME].include?((column["type"] || column[:type]).to_s)
        end
        numeric = description.fetch("columns").select do |column|
          %w[INTEGER REAL].include?((column["type"] || column[:type]).to_s)
        end.map { |column| (column["name"] || column[:name]).to_s }
        time_column = temporal && (temporal["name"] || temporal[:name]).to_s
        order = time_column && "#{time_column}:asc"
        rows = @dataset_engine.query(
          entry.fetch("dataset_id"), order: order, limit: MAX_ROWS_PER_DATASET
        )
        result[entry.fetch("slug")] = {
          "metadata" => description.reject { |key, _value| key == "columns" || key == "schema_history" },
          "columns" => description.fetch("columns"), "time_column" => time_column,
          "numeric_columns" => numeric, "rows" => rows,
          "statistics" => @dataset_engine.stats(entry.fetch("dataset_id"))
        }
      rescue StructuredDataset::Error
        next
      end
    end

    def dataset_signature(datasets)
      value = datasets.keys.sort.map do |slug|
        source = datasets.fetch(slug)
        {
          "slug" => slug, "dataset_id" => source.dig("metadata", "dataset_id"),
          "schema_version" => source.dig("metadata", "schema_version"),
          "rows" => source.fetch("rows").map do |row|
            [row["row_id"], row["updated_at"], row["intent_id"]]
          end
        }
      end
      Digest::SHA256.hexdigest(KnowledgeExtraction::Support.canonical_json(value))
    end

    def aggregate(question, context, plugins, fragments, dataset_signature)
      factors = unique(
        fragments.flat_map { |fragment| fragment.fetch("possible_factors") }, "factor_id"
      ).sort_by { |item| [-item.fetch("confidence"), item.fetch("factor_id")] }
      correlations = fragments.flat_map { |fragment| fragment.fetch("correlations") }
      graph = unique(fragments.flat_map { |fragment| fragment.fetch("graph_evidence") }, "record_id")
      activity = unique(fragments.flat_map { |fragment| fragment.fetch("activity_evidence") }, "id")
      windows = fragments.flat_map { |fragment| fragment.fetch("time_windows") }.uniq
      recommendations = unique(
        fragments.flat_map { |fragment| fragment.fetch("recommendations") }, "recommendation_id"
      )
      recommendations, decision_trace = DecisionAdapter.new.rank(
        question: question, recommendations: recommendations,
        snapshot_digest: @snapshot.digest, as_of: context.as_of
      )
      limitations = fragments.flat_map { |fragment| fragment.fetch("limitations") }.map(&:to_s).uniq
      scores = fragments.map { |fragment| fragment.fetch("confidence").to_f }.select(&:positive?)
      confidence = scores.empty? ? 0.0 : (scores.sum / scores.length).round(6)
      primary = fragments.find { |fragment| fragment.fetch("plugin") != "generic" } || fragments.first
      used_slugs = factors.flat_map { |factor| factor.fetch("datasets", []) }.uniq.sort
      used_slugs = context.datasets.keys.sort if used_slugs.empty?
      dataset_evidence = used_slugs.map do |slug|
        source = context.dataset(slug)
        next unless source

        metadata = source.fetch("metadata")
        {
          "dataset_id" => metadata.fetch("dataset_id"), "slug" => slug,
          "schema_version" => metadata.fetch("schema_version"),
          "row_count" => source.dig("statistics", "row_count"),
          "time_column" => source.fetch("time_column", nil),
          "numeric_columns" => source.fetch("numeric_columns")
        }.reject { |_key, value| value.nil? }
      end.compact
      result = {
        "question" => question,
        "intent" => "analysis.cross_knowledge",
        "summary" => primary ? primary.fetch("summary") : "No installed analysis plugin could evaluate the question.",
        "confidence" => confidence,
        "possible_factors" => factors,
        "datasets" => dataset_evidence,
        "graph_evidence" => graph,
        "activity_evidence" => activity,
        "intelligence_evidence" => context.intelligence_findings,
        "planning_signals" => context.planning_signals,
        "event_evidence" => context.events.last(50).map do |event|
          {
            "event_id" => event.id, "type" => event.type,
            "timestamp" => event.timestamp, "source" => event.source
          }
        end,
        "time_windows" => windows,
        "correlations" => correlations,
        "recommendations" => recommendations,
        "decision_trace" => decision_trace,
        "limitations" => limitations,
        "analysis_modules" => plugins.map do |plugin|
          { "name" => plugin.name, "contributions" => plugin.contributions }
        end,
        "explainability" => {
          "causal_language" => "possible_contributing_factors",
          "causality_established" => false,
          "ranking" => "confidence_desc_then_stable_id",
          "dataset_signature" => dataset_signature,
          "graph_snapshot_digest" => @snapshot.digest
        },
        "subsystems" => %w[
          intent_classifier planning_engine decision_engine knowledge_intelligence knowledge_graph
          structured_datasets correlation_engine knowledge_activity event_bus knowledge_cache
        ]
      }
      result["analysis_digest"] = Digest::SHA256.hexdigest(
        KnowledgeExtraction::Support.canonical_json(result)
      )
      result
    end

    def intelligence_findings(date)
      run = KnowledgeIntelligence::AnalysisEngine.new(
        snapshot: @snapshot, analyzers: KnowledgeIntelligence::DefaultAnalyzers.build,
        as_of: date
      ).run(names: %w[timeline anomaly consistency])
      run.findings.reject do |finding|
        finding.entity_ids.any? do |entity_id|
          record = @snapshot.record(entity_id)
          record && record["sensitivity"] == "restricted"
        end
      end.first(50).map do |finding|
        {
          "finding_id" => finding.finding_id, "kind" => finding.kind,
          "title" => finding.title, "confidence" => finding.confidence,
          "entity_ids" => finding.entity_ids, "explanation" => finding.explanation
        }
      end
    rescue KnowledgeIntelligence::Error, ArgumentError
      []
    end

    def planning_signals
      StructuredDataset::PlanningAdapter.new(engine: @dataset_engine, clock: @clock).signals.first(100)
    rescue StructuredDataset::Error
      []
    end

    def safe_activities
      @timeline.recent(limit: 200).reverse
    rescue KnowledgeActivity::Error, KnowledgeOrchestration::Error
      []
    end

    def safe_events
      @event_store.events.last(200)
    rescue KnowledgeOrchestration::Error
      []
    end

    def resolve_window(question, from, to, as_of)
      upper = to ? parse_time(to) : Time.utc(as_of.year, as_of.month, as_of.day, 23, 59, 59)
      lower = from && parse_time(from)
      unless lower
        match = question.match(/\b(?:last|during the last)\s+(\d+)\s+(day|days|week|weeks|month|months|year|years)\b/i)
        if match
          count = match[1].to_i
          lower = case match[2].downcase
                  when /day/ then upper - count * 86_400
                  when /week/ then upper - count * 7 * 86_400
                  when /month/ then shift_months(upper, count)
                  when /year/ then shift_months(upper, count * 12)
                  end
        end
      end
      { "from" => lower, "to" => upper }
    end

    def shift_months(time, count)
      date = Date.new(time.year, time.month, [time.day, 28].min) << count
      Time.utc(date.year, date.month, date.day, time.hour, time.min, time.sec)
    end

    def parse_date(value)
      return value if value.is_a?(Date) && !value.is_a?(DateTime)
      return value.to_date if value.respond_to?(:to_date)

      Date.iso8601(value.to_s)
    rescue ArgumentError
      Time.iso8601(value.to_s).to_date
    end

    def parse_time(value)
      return value if value.is_a?(Time)
      return Time.utc(value.year, value.month, value.day) if value.is_a?(Date)

      Time.iso8601(value.to_s)
    rescue ArgumentError
      date = Date.iso8601(value.to_s)
      Time.utc(date.year, date.month, date.day)
    end

    def unique(items, key)
      items.each_with_object({}) do |item, result|
        identifier = item[key] || Digest::SHA256.hexdigest(KnowledgeExtraction::Support.canonical_json(item))
        current = result[identifier]
        result[identifier] = item if current.nil? || item.fetch("confidence", 0.0) > current.fetch("confidence", 0.0)
      end.values
    end
  end
end
