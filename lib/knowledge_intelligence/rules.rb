# frozen_string_literal: true

require "yaml"

module KnowledgeIntelligence
  class RecommendationRule
    attr_reader :id, :finding_kinds, :minimum_confidence, :kind, :title,
                :severity, :priority, :tags, :message

    def initialize(data)
      @id = data.fetch("id").to_s.freeze
      match = data.fetch("match")
      output = data.fetch("recommendation")
      @finding_kinds = Array(match.fetch("finding_kinds")).map(&:to_s).freeze
      @minimum_confidence = match.fetch("minimum_confidence", 0.0).to_f
      @kind = output.fetch("kind").to_s.freeze
      @title = output.fetch("title").to_s.freeze
      @severity = output.fetch("severity", "info").to_s.freeze
      @priority = output.fetch("priority", "normal").to_s.freeze
      @tags = Array(output.fetch("tags", [])).map(&:to_s).freeze
      @message = output.fetch("message").to_s.freeze
      freeze
    end

    def match?(finding)
      finding_kinds.include?(finding.kind) && finding.confidence >= minimum_confidence
    end
  end

  class RuleEngine
    attr_reader :rules

    def self.load(path)
      data = YAML.safe_load(File.read(path), aliases: false)
      new(Array(data.fetch("rules")))
    rescue Psych::SyntaxError => error
      raise Error, "invalid intelligence rule configuration: #{error.message}"
    end

    def initialize(rule_data)
      @rules = Array(rule_data).map { |data| RecommendationRule.new(data) }.sort_by(&:id).freeze
      freeze
    end

    def recommendations(source_findings, context:, analyzer_name: "recommendation")
      Array(source_findings).sort_by(&:finding_id).each_with_object([]) do |source, result|
        rules.select { |rule| rule.match?(source) }.each do |rule|
          primary = source.entity_ids.first
          entity = context.snapshot.record(primary)
          label = entity&.name || primary || "knowledge graph"
          title = rule.title.gsub("%{entity}", label.to_s)
          explanation = rule.message.gsub("%{entity}", label.to_s).gsub("%{why}", source.explanation)
          result << Finding.new(
            analyzer: analyzer_name, kind: rule.kind, title: title,
            entity_ids: source.entity_ids, confidence: source.confidence,
            evidence: source.evidence, explanation: explanation,
            severity: rule.severity, priority: rule.priority,
            tags: rule.tags + ["rule:#{rule.id}"], graph_path: source.graph_path,
            features: source.features,
            details: { rule_id: rule.id, source_finding_id: source.finding_id,
                       source_kind: source.kind }, intent_proposals: source.intent_proposals
          )
        end
      end
    end
  end
end
