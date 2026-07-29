# frozen_string_literal: true

require "date"

module KnowledgeIntelligence
  class FeatureDefinition
    attr_reader :name, :version, :scope, :dependencies, :calculator

    def initialize(name:, version:, scope:, dependencies: [], &calculator)
      @name = name.to_s.freeze
      @version = version.to_s.freeze
      @scope = scope.to_s.freeze
      @dependencies = Array(dependencies).map(&:to_s).freeze
      @calculator = calculator
      raise ArgumentError, "feature calculator is required" unless @calculator
      freeze
    end
  end

  class FeatureRegistry
    def initialize
      @definitions = {}
    end

    def register(name, version:, scope:, dependencies: [], &calculator)
      key = name.to_s
      raise ArgumentError, "feature already registered: #{key}" if @definitions.key?(key)

      @definitions[key] = FeatureDefinition.new(
        name: key, version: version, scope: scope, dependencies: dependencies, &calculator
      )
      self
    end

    def fetch(name)
      @definitions.fetch(name.to_s) { raise UnknownFeature, "unknown feature #{name.inspect}" }
    end

    def names
      @definitions.keys.sort.freeze
    end

    def freeze
      @definitions.freeze
      super
    end
  end

  class FeatureContext
    attr_reader :snapshot, :as_of, :engine, :config

    def initialize(snapshot:, as_of:, engine:, config:)
      @snapshot = snapshot
      @as_of = as_of
      @engine = engine
      @config = config.dup.freeze
    end

    def feature(name, subject_id:, object_id: nil, params: {})
      engine.fetch(name, subject_id: subject_id, object_id: object_id, params: params)
    end

    def social_graph
      @social_graph ||= Projection.social(snapshot, as_of: as_of)
    end

    def social_metrics
      @social_metrics ||= {
        degree: GraphAlgorithms.degree_centrality(social_graph),
        betweenness: GraphAlgorithms.betweenness_centrality(
          social_graph, max_sources: config.fetch(:betweenness_sources, 128)
        ),
        communities: GraphAlgorithms.communities(social_graph),
        components: GraphAlgorithms.connected_components(social_graph),
        bridges: GraphAlgorithms.bridges(social_graph)
      }.freeze
    end

    def shortest_path(source_id, target_id)
      @shortest_path_trees ||= {}
      source = source_id.to_s
      @shortest_path_trees[source] ||= GraphAlgorithms.shortest_path_tree(social_graph, source)
      GraphAlgorithms.path_from_tree(@shortest_path_trees[source], target_id)
    end
  end

  class FeatureEngine
    attr_reader :snapshot, :registry, :as_of

    def initialize(snapshot:, registry:, as_of: Date.today, config: {})
      @snapshot = snapshot
      @registry = registry
      @as_of = as_of.is_a?(Date) ? as_of : Date.parse(as_of.to_s)
      @config = config.dup.freeze
      @cache = {}
      @active = {}
      @computations = Hash.new(0)
      @cache_hits = 0
      @context = FeatureContext.new(snapshot: snapshot, as_of: @as_of, engine: self, config: @config)
    end

    def fetch(name, subject_id:, object_id: nil, params: {})
      definition = registry.fetch(name)
      subject = snapshot.fetch(subject_id)
      snapshot.fetch(object_id) if object_id
      if definition.scope == "pair" && object_id.nil?
        raise InvalidFeatureRequest, "feature #{name} requires object_id"
      end
      key = [definition.name, definition.version, subject.id, object_id && object_id.to_s,
             Stable.json(params), as_of.iso8601].freeze
      if @cache.key?(key)
        @cache_hits += 1
        return @cache[key]
      end
      raise FeatureCycle, "cyclic feature dependency at #{definition.name}" if @active[key]

      @active[key] = true
      value = definition.calculator.call(
        @context, subject.id, object_id && object_id.to_s, Immutable.copy(params)
      )
      unless value.is_a?(FeatureValue) && value.name == definition.name && value.version == definition.version
        raise InvalidFeatureRequest, "feature #{definition.name} returned an invalid value"
      end
      @computations[definition.name] += 1
      @cache[key] = value
    ensure
      @active.delete(key) if key
    end

    def metrics
      {
        computations: @computations.sort.to_h,
        cache_hits: @cache_hits,
        cached_values: @cache.length
      }.freeze
    end
  end

  module DefaultFeatures
    CONFIDENCE = { "confirmed" => 1.0, "probable" => 0.75, "possible" => 0.45, "disputed" => 0.15 }.freeze
    CLOSENESS = { "close" => 1.0, "regular" => 0.75, "acquaintance" => 0.45, "weak" => 0.2 }.freeze
    PROFILE_SIGNALS = {
      "person" => %w[email phone organization location interest relationship],
      "organization" => %w[domain website industry location people],
      "project" => %w[status timeline technology topic participants],
      "default" => %w[name relationship provenance]
    }.freeze

    module_function

    def registry
      registry = FeatureRegistry.new
      register_recency(registry)
      register_frequency(registry)
      register_trust(registry)
      register_relationship_strength(registry)
      register_distance(registry)
      register_influence(registry)
      register_completeness(registry)
      register_community(registry)
      registry.freeze
    end

    def register_recency(registry)
      registry.register("recency_score", version: "1.0.0", scope: "pair_or_self") do |context, subject_id, object_id, params|
        half_life = (params["half_life_days"] || context.config.fetch(:recency_half_life_days, 90)).to_f
        counterpart_id = object_id || context.snapshot.self_id
        interactions = counterpart_id && counterpart_id != subject_id ?
          context.snapshot.interactions_between(counterpart_id, subject_id, as_of: context.as_of, substantive_only: true) :
          context.snapshot.interactions_for(subject_id, as_of: context.as_of, substantive_only: true)
        latest = interactions.max_by { |record| context.snapshot.parse_time(record["starts_at"]) || Time.at(0) }
        if latest
          date = context.snapshot.parse_time(latest["starts_at"]).to_date
          days = [(context.as_of - date).to_i, 0].max
          score = Math.exp(-Math.log(2.0) * days / [half_life, 1.0].max)
          FeatureValue.new(
            name: "recency_score", version: "1.0.0", subject_id: subject_id, object_id: object_id, value: score,
            evidence: [context.snapshot.evidence(latest, field: "starts_at")],
            explanation: "Latest substantive interaction was #{days} days ago; half-life is #{half_life.to_i} days.",
            metadata: { days_since_interaction: days, half_life_days: half_life.to_i,
                        latest_interaction_id: latest.id, counterpart_id: counterpart_id }
          )
        else
          FeatureValue.new(
            name: "recency_score", version: "1.0.0", subject_id: subject_id, object_id: object_id, value: 0.0,
            evidence: [], explanation: "No substantive interaction is recorded.",
            metadata: { days_since_interaction: nil, half_life_days: half_life.to_i,
                        counterpart_id: counterpart_id }
          )
        end
      end
    end

    def register_frequency(registry)
      registry.register("interaction_frequency", version: "1.0.0", scope: "pair_or_self") do |context, subject_id, object_id, params|
        window = (params["window_days"] || context.config.fetch(:frequency_window_days, 365)).to_i
        counterpart_id = object_id || context.snapshot.self_id
        interactions = counterpart_id && counterpart_id != subject_id ?
          context.snapshot.interactions_between(counterpart_id, subject_id, as_of: context.as_of) :
          context.snapshot.interactions_for(subject_id, as_of: context.as_of)
        cutoff = context.as_of - window
        recent = interactions.select do |record|
          starts = context.snapshot.parse_time(record["starts_at"])
          starts && starts.to_date >= cutoff
        end
        weights = { "substantive" => 1.0, "incidental" => 0.25, "mass" => 0.05 }
        weighted = recent.sum { |record| weights.fetch(record["contact_weight"], 0.0) }
        score = 1.0 - Math.exp(-weighted / 6.0)
        FeatureValue.new(
          name: "interaction_frequency", version: "1.0.0", subject_id: subject_id, object_id: object_id, value: score,
          evidence: recent.map { |record| context.snapshot.evidence(record, field: "contact_weight") },
          explanation: "#{recent.length} interactions (weighted #{weighted.round(2)}) occurred in the last #{window} days.",
          metadata: { window_days: window, interaction_count: recent.length,
                      weighted_count: weighted.round(4), counterpart_id: counterpart_id }
        )
      end
    end

    def register_trust(registry)
      registry.register("trust_score", version: "1.0.0", scope: "entity") do |context, subject_id, _object, _params|
        relationships = context.snapshot.relationships(as_of: context.as_of, entity_id: subject_id)
        if relationships.empty?
          score = 0.5
          explanation = "No relationship assertions are available; neutral trust prior applied."
        else
          confidence = relationships.sum { |record| CONFIDENCE.fetch(record["confidence"], 0.35) } / relationships.length
          sourced = relationships.count do |record|
            !Array(record["source_links"]).empty? || !Array(record["source_urls"]).empty?
          end.to_f / relationships.length
          human = relationships.count { |record| record["asserted_by"] == "human" }.to_f / relationships.length
          score = 0.7 * confidence + 0.2 * sourced + 0.1 * human
          explanation = "Trust combines assertion confidence (70%), source coverage (20%), and human attribution (10%)."
        end
        FeatureValue.new(
          name: "trust_score", version: "1.0.0", subject_id: subject_id, value: score,
          evidence: relationships.map { |record| context.snapshot.evidence(record, field: "confidence") },
          explanation: explanation, metadata: { relationship_count: relationships.length }
        )
      end
    end

    def register_relationship_strength(registry)
      registry.register(
        "relationship_strength", version: "1.0.0", scope: "pair_or_self",
        dependencies: %w[recency_score interaction_frequency trust_score]
      ) do |context, subject_id, object_id, _params|
        recency = context.feature("recency_score", subject_id: subject_id, object_id: object_id)
        frequency = context.feature("interaction_frequency", subject_id: subject_id, object_id: object_id)
        trust = context.feature("trust_score", subject_id: subject_id)
        counterpart_id = object_id || context.snapshot.self_id
        direct = if counterpart_id
                   context.snapshot.relationships(as_of: context.as_of, entity_id: subject_id).select do |record|
                     [record["subject_id"], record["object_id"]].sort == [counterpart_id, subject_id].sort
                   end
                 else
                   []
                 end
        closeness = direct.map { |record| CLOSENESS.fetch(record["closeness"], 0.5) }.max || 0.0
        introductions = context.snapshot.introductions_for(subject_id, role: "introducer").count do |record|
          record["assertion_status"] == "asserted"
        end
        connector = [introductions / 3.0, 1.0].min
        score = 0.35 * recency.value + 0.25 * frequency.value + 0.2 * closeness +
                0.1 * trust.value + 0.1 * connector
        evidence = recency.evidence + frequency.evidence + trust.evidence +
                   direct.map { |record| context.snapshot.evidence(record, field: "closeness") }
        FeatureValue.new(
          name: "relationship_strength", version: "1.0.0", subject_id: subject_id,
          object_id: object_id, value: score,
          evidence: evidence,
          explanation: "Strength = 35% recency + 25% interaction frequency + 20% asserted closeness + 10% trust + 10% connector value.",
          metadata: { recency: recency.value, frequency: frequency.value, closeness: closeness,
                      trust: trust.value, connector: connector, counterpart_id: counterpart_id }
        )
      end
    end

    def register_distance(registry)
      registry.register("graph_distance", version: "1.0.0", scope: "pair") do |context, subject_id, object_id, _params|
        path = context.shortest_path(subject_id, object_id)
        value = path ? path.length - 1 : nil
        edge_evidence = []
        if path
          path.each_cons(2) do |first, second|
            context.social_graph.edge_ids(first, second).each do |edge_id|
              edge = context.social_graph.edge_records[edge_id]
              record = edge && context.snapshot.record(edge["record_id"])
              edge_evidence << context.snapshot.evidence(record) if record
            end
          end
        end
        FeatureValue.new(
          name: "graph_distance", version: "1.0.0", subject_id: subject_id, object_id: object_id,
          value: value, evidence: edge_evidence,
          explanation: path ? "Shortest social path has #{value} edge(s)." : "No social path is available.",
          metadata: { path: path || [] }
        )
      end
    end

    def register_influence(registry)
      registry.register("influence_score", version: "1.0.0", scope: "entity") do |context, subject_id, _object, _params|
        metrics = context.social_metrics
        introductions = context.snapshot.introductions_for(subject_id, role: "introducer").count do |record|
          record["assertion_status"] == "asserted"
        end
        connector = [introductions / 5.0, 1.0].min
        degree = metrics[:degree].fetch(subject_id, 0.0)
        betweenness = metrics[:betweenness].fetch(subject_id, 0.0)
        score = 0.45 * degree + 0.35 * betweenness + 0.2 * connector
        FeatureValue.new(
          name: "influence_score", version: "1.0.0", subject_id: subject_id, value: score,
          evidence: [],
          explanation: "Influence = 45% degree centrality + 35% betweenness + 20% completed-introduction activity.",
          metadata: { degree_centrality: degree, betweenness: betweenness,
                      introduction_connector: connector, introduction_count: introductions }
        )
      end
    end

    def register_completeness(registry)
      registry.register("completeness_score", version: "1.0.0", scope: "entity") do |context, subject_id, _object, _params|
        record = context.snapshot.fetch(subject_id)
        signals = completeness_signals(context.snapshot, record, context.as_of)
        expected = PROFILE_SIGNALS.fetch(record.type, PROFILE_SIGNALS["default"])
        present = expected.select { |signal| signals[signal] }
        score = present.length.to_f / expected.length
        FeatureValue.new(
          name: "completeness_score", version: "1.0.0", subject_id: subject_id, value: score,
          evidence: completeness_evidence(context.snapshot, record),
          explanation: "#{present.length} of #{expected.length} documented profile signals are present.",
          metadata: { present: present, missing: expected - present }
        )
      end
    end

    def register_community(registry)
      registry.register("community_membership", version: "1.0.0", scope: "entity") do |context, subject_id, _object, _params|
        label = context.social_metrics[:communities][subject_id]
        members = context.social_metrics[:communities].select { |_id, value| value == label }.keys.sort
        FeatureValue.new(
          name: "community_membership", version: "1.0.0", subject_id: subject_id,
          value: label && "community:#{label}", evidence: [],
          explanation: label ? "Deterministic label propagation assigned a community of #{members.length} people." :
                               "The entity is outside the person social projection.",
          metadata: { representative_id: label, member_ids: members, size: members.length }
        )
      end
    end

    def completeness_signals(snapshot, record, as_of)
      relationships = snapshot.relationships(as_of: as_of, entity_id: record.id)
      predicates = relationships.map { |item| item["predicate"] }
      {
        "email" => !Array(record["emails"]).empty?, "phone" => !Array(record["phones"]).empty?,
        "organization" => !(predicates & %w[works_for founded leads member_of]).empty?,
        "location" => !(predicates & %w[lives_in born_in headquartered_in has_office_in incorporated_in]).empty?,
        "interest" => !(predicates & %w[likes interested_in expert_in]).empty?,
        "relationship" => !relationships.empty?, "domain" => !Array(record["domains"]).empty?,
        "website" => !record["website"].to_s.empty?, "industry" => !Array(record["industries"]).empty?,
        "people" => relationships.any? { |item| snapshot.record(item["subject_id"])&.type == "person" },
        "status" => !record["project_status"].to_s.empty?,
        "timeline" => !!(record["started_on"] || record["target_end_on"] || record["ended_on"]),
        "technology" => !Array(record["technologies"]).empty?, "topic" => !Array(record["topics"]).empty?,
        "participants" => relationships.any?, "name" => !record.name.to_s.empty?,
        "provenance" => !!(record["created_by"] && record["updated_by"])
      }
    end
    private_class_method :completeness_signals

    def completeness_evidence(snapshot, record)
      fields = %w[emails phones domains website industries project_status started_on target_end_on technologies topics]
      fields.select { |field| record[field] && !Array(record[field]).empty? }.map do |field|
        snapshot.evidence(record, field: field)
      end
    end
    private_class_method :completeness_evidence
  end
end
