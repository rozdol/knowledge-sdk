# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "time"

module KnowledgeIntelligence
  module Immutable
    module_function

    def copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key.to_s.freeze] = copy(item) }.freeze
      when Array
        value.map { |item| copy(item) }.freeze
      when Time, Date, DateTime, Numeric, Symbol, TrueClass, FalseClass, NilClass
        value.freeze
      else
        value.to_s.dup.freeze
      end
    end

    def canonical(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          result[key] = canonical(value[original])
        end
      when Array
        value.map { |item| canonical(item) }
      when Time, DateTime
        value.iso8601
      when Date
        value.iso8601
      when Symbol
        value.to_s
      else
        value
      end
    end
  end

  module Stable
    ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ".freeze
    module_function

    def json(value)
      JSON.generate(Immutable.canonical(value))
    end

    def id(prefix, *parts)
      number = Digest::SHA256.digest(json(parts)).unpack1("H*").to_i(16)
      encoded = 26.times.map do
        character = ALPHABET[number % 32]
        number /= 32
        character
      end.reverse.join
      "#{prefix}_#{encoded}"
    end
  end

  class Evidence
    attr_reader :evidence_id, :record_id, :path, :field, :value, :role

    def initialize(record_id:, path:, field: nil, value: nil, role: "supporting")
      @record_id = record_id.to_s.freeze
      @path = path.to_s.freeze
      @field = field && field.to_s.freeze
      @value = Immutable.copy(value)
      @role = role.to_s.freeze
      @evidence_id = Stable.id("evidence", @record_id, @path, @field, @value, @role).freeze
      freeze
    end

    def to_h
      {
        evidence_id: evidence_id, record_id: record_id, path: path,
        field: field, value: value, role: role
      }.reject { |_key, item| item.nil? }
    end
  end

  class FeatureValue
    attr_reader :name, :version, :subject_id, :object_id, :value,
                :evidence, :explanation, :metadata

    def initialize(name:, version:, subject_id:, value:, evidence:, explanation:,
                   object_id: nil, metadata: {})
      @name = name.to_s.freeze
      @version = version.to_s.freeze
      @subject_id = subject_id.to_s.freeze
      @object_id = object_id && object_id.to_s.freeze
      @value = value.is_a?(Float) ? value.round(6) : Immutable.copy(value)
      @evidence = Array(evidence).sort_by(&:evidence_id).freeze
      @explanation = explanation.to_s.freeze
      @metadata = Immutable.copy(metadata)
      freeze
    end

    def to_h
      {
        name: name, version: version, subject_id: subject_id, object_id: object_id,
        value: value, evidence: evidence.map(&:to_h), explanation: explanation,
        metadata: metadata
      }.reject { |_key, item| item.nil? }
    end
  end

  class IntentProposal
    attr_reader :proposal_id, :planned_intent_id, :intent, :finding_id,
                :evidence_ids, :planning_confidence, :risk,
                :approval_requirement, :blocked_reasons

    def initialize(intent:, finding_id:, evidence_ids:, planning_confidence:,
                   risk: "medium", approval_requirement: "human_review", blocked_reasons: [])
      @intent = Immutable.copy(intent)
      # Compatibility with the existing approval pipeline starts with a payload
      # that the existing IntentFactory can reconstruct. Nothing is executed here.
      KnowledgeGraph::IntentFactory.build(Immutable.canonical(@intent))
      @finding_id = finding_id.to_s.freeze
      @evidence_ids = Array(evidence_ids).map(&:to_s).uniq.sort.freeze
      @planning_confidence = [[planning_confidence.to_f, 0.0].max, 1.0].min.round(6)
      @risk = risk.to_s.freeze
      @approval_requirement = approval_requirement.to_s.freeze
      @blocked_reasons = Array(blocked_reasons).map(&:to_s).sort.freeze
      @planned_intent_id = Stable.id("planned-intent", @finding_id, @intent).freeze
      @proposal_id = Stable.id("intelligence-proposal", @planned_intent_id).freeze
      freeze
    end

    def to_h
      {
        proposal_id: proposal_id, planned_intent_id: planned_intent_id,
        intent: intent, finding_id: finding_id, evidence_ids: evidence_ids,
        planning_confidence: planning_confidence, risk: risk,
        approval_requirement: approval_requirement, blocked_reasons: blocked_reasons,
        executable: false
      }
    end
  end

  class Finding
    SEVERITIES = %w[info low medium high critical].freeze
    PRIORITIES = %w[low normal high critical].freeze

    attr_reader :finding_id, :analyzer, :kind, :title, :entity_ids, :confidence,
                :evidence, :explanation, :severity, :priority, :tags,
                :graph_path, :features, :details, :intent_proposals

    def initialize(analyzer:, kind:, title:, entity_ids:, confidence:, evidence:,
                   explanation:, severity: "info", priority: "normal", tags: [],
                   graph_path: [], features: {}, details: {}, intent_proposals: [])
      raise ArgumentError, "invalid severity #{severity.inspect}" unless SEVERITIES.include?(severity.to_s)
      raise ArgumentError, "invalid priority #{priority.inspect}" unless PRIORITIES.include?(priority.to_s)

      @analyzer = analyzer.to_s.freeze
      @kind = kind.to_s.freeze
      @title = title.to_s.freeze
      @entity_ids = Array(entity_ids).map(&:to_s).uniq.freeze
      @confidence = [[confidence.to_f, 0.0].max, 1.0].min.round(6)
      @evidence = Array(evidence).uniq { |item| item.evidence_id }.sort_by(&:evidence_id).freeze
      @explanation = explanation.to_s.freeze
      @severity = severity.to_s.freeze
      @priority = priority.to_s.freeze
      @tags = Array(tags).map(&:to_s).uniq.sort.freeze
      @graph_path = Array(graph_path).map(&:to_s).freeze
      @features = Immutable.copy(features)
      @details = Immutable.copy(details)
      @finding_id = Stable.id(
        "finding", @analyzer, @kind, @entity_ids, @evidence.map(&:evidence_id), @details
      ).freeze
      @intent_proposals = Array(intent_proposals).freeze
      freeze
    end

    def with_proposals(proposals)
      self.class.new(
        analyzer: analyzer, kind: kind, title: title, entity_ids: entity_ids,
        confidence: confidence, evidence: evidence, explanation: explanation,
        severity: severity, priority: priority, tags: tags, graph_path: graph_path,
        features: features, details: details, intent_proposals: proposals
      )
    end

    def to_h
      {
        finding_id: finding_id, analyzer: analyzer, kind: kind, title: title,
        entity_ids: entity_ids, confidence: confidence,
        evidence: evidence.map(&:to_h), explanation: explanation,
        severity: severity, priority: priority, tags: tags,
        graph_path: graph_path, features: features, details: details,
        intent_proposals: intent_proposals.map(&:to_h)
      }
    end
  end

  class AnalysisResult
    attr_reader :analyzer, :version, :execution_time_ms, :findings, :metrics

    def initialize(analyzer:, version:, findings:, execution_time_ms: 0, metrics: {})
      @analyzer = analyzer.to_s.freeze
      @version = version.to_s.freeze
      @execution_time_ms = execution_time_ms.to_f.round(3)
      @findings = Array(findings).sort_by { |finding| [finding.priority, finding.finding_id] }.freeze
      @metrics = Immutable.copy(metrics)
      freeze
    end

    def to_h
      {
        analyzer: analyzer, version: version, execution_time_ms: execution_time_ms,
        findings: findings.map(&:to_h), metrics: metrics
      }
    end
  end

  class RunResult
    attr_reader :snapshot_digest, :as_of, :results, :feature_metrics

    def initialize(snapshot_digest:, as_of:, results:, feature_metrics: {})
      @snapshot_digest = snapshot_digest.to_s.freeze
      @as_of = as_of.iso8601.freeze
      @results = Array(results).sort_by(&:analyzer).freeze
      @feature_metrics = Immutable.copy(feature_metrics)
      freeze
    end

    def findings
      results.flat_map(&:findings).sort_by(&:finding_id).freeze
    end

    def to_h
      {
        snapshot_digest: snapshot_digest, as_of: as_of,
        results: results.map(&:to_h), feature_metrics: feature_metrics
      }
    end
  end
end
