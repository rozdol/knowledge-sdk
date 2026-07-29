# frozen_string_literal: true

require "date"

module KnowledgeIntelligence
  class AnalysisContext
    attr_reader :snapshot, :features, :as_of, :config, :prior_results

    def initialize(snapshot:, features:, as_of:, config: {}, prior_results: [])
      @snapshot = snapshot
      @features = features
      @as_of = as_of
      @config = config.dup.freeze
      @prior_results = Array(prior_results).dup.freeze
      freeze
    end

    def with_prior_results(results)
      self.class.new(
        snapshot: snapshot, features: features, as_of: as_of,
        config: config, prior_results: results
      )
    end

    def evidence(record, field: nil, value: nil, role: "supporting")
      snapshot.evidence(record, field: field, value: value, role: role)
    end

    def person_name(id)
      snapshot.record(id)&.name || id.to_s
    end
  end

  class Analyzer
    NAME = "base"
    VERSION = "1.0.0"

    def name
      self.class::NAME
    end

    def version
      self.class::VERSION
    end

    def dependencies
      self.class.const_defined?(:DEPENDENCIES, false) ? self.class::DEPENDENCIES : []
    end

    def analyze(graph, feature_engine: nil, as_of: Date.today, config: {}, prior_results: [])
      context = if graph.is_a?(AnalysisContext)
                  graph
                elsif graph.is_a?(GraphSnapshot)
                  date = as_of.is_a?(Date) ? as_of : Date.parse(as_of.to_s)
                  features = feature_engine || FeatureEngine.new(
                    snapshot: graph, registry: DefaultFeatures.registry, as_of: date
                  )
                  AnalysisContext.new(
                    snapshot: graph, features: features, as_of: date,
                    config: config, prior_results: prior_results
                  )
                else
                  raise ArgumentError, "analyze expects a GraphSnapshot or AnalysisContext"
                end
      perform(context)
    end

    def perform(_context)
      raise NotImplementedError
    end

    private

    def result(findings, metrics: {}, execution_time_ms: 0)
      AnalysisResult.new(
        analyzer: name, version: version, findings: findings,
        metrics: metrics, execution_time_ms: execution_time_ms
      )
    end

    def finding(**attributes)
      Finding.new({ analyzer: name }.merge(attributes))
    end
  end

  class AnalysisEngine
    attr_reader :snapshot, :feature_engine, :analyzers, :as_of

    def initialize(snapshot:, analyzers:, feature_registry: DefaultFeatures.registry,
                   as_of: Date.today, feature_config: {}, analyzer_config: {}, profile: false)
      @snapshot = snapshot
      @analyzers = Array(analyzers).sort_by(&:name).freeze
      duplicate_names = @analyzers.group_by(&:name).select { |_name, items| items.length > 1 }.keys
      raise ArgumentError, "duplicate analyzers: #{duplicate_names.join(', ')}" unless duplicate_names.empty?
      @as_of = as_of.is_a?(Date) ? as_of : Date.parse(as_of.to_s)
      @feature_engine = FeatureEngine.new(
        snapshot: snapshot, registry: feature_registry, as_of: @as_of, config: feature_config
      )
      @analyzer_config = analyzer_config.dup.freeze
      @profile = profile
    end

    def run(names: nil)
      selected = ordered_selection(names)
      digest_before = snapshot.digest
      results = []
      selected.each do |analyzer|
        context = AnalysisContext.new(
          snapshot: snapshot, features: feature_engine, as_of: as_of,
          config: @analyzer_config, prior_results: results
        )
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        analysis = analyzer.analyze(context)
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        unless analysis.is_a?(AnalysisResult) && analysis.analyzer == analyzer.name
          raise Error, "analyzer #{analyzer.name} returned an invalid result"
        end
        analysis = AnalysisResult.new(
          analyzer: analysis.analyzer, version: analysis.version, findings: analysis.findings,
          metrics: analysis.metrics, execution_time_ms: @profile ? elapsed : 0
        )
        results << analysis
      end
      raise ReadOnlyViolation, "graph snapshot changed during analysis" unless snapshot.digest == digest_before

      RunResult.new(
        snapshot_digest: snapshot.digest, as_of: as_of,
        results: results, feature_metrics: feature_engine.metrics
      )
    end

    private

    def ordered_selection(names)
      by_name = analyzers.each_with_object({}) { |analyzer, result| result[analyzer.name] = analyzer }
      requested = names ? Array(names).map(&:to_s) : by_name.keys.sort
      missing = requested - by_name.keys
      raise UnknownAnalyzer, "unknown analyzer(s): #{missing.join(', ')}" unless missing.empty?

      ordered = []
      active = {}
      visited = {}
      visit = lambda do |name|
        raise UnknownAnalyzer, "analyzer #{name} depends on an unknown analyzer" unless by_name.key?(name)
        raise Error, "cyclic analyzer dependency at #{name}" if active[name]
        return if visited[name]

        active[name] = true
        by_name[name].dependencies.sort.each { |dependency| visit.call(dependency) }
        active.delete(name)
        visited[name] = true
        ordered << by_name[name]
      end
      requested.sort.each { |name| visit.call(name) }
      ordered.freeze
    end
  end
end
