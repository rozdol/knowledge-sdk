# frozen_string_literal: true

module KnowledgeIntelligence
  module Analyzers
    class Recommendation < Analyzer
      NAME = "recommendation"
      VERSION = "1.0.0"
      DEPENDENCIES = %w[relationship knowledge_gap opportunity followup activity project anomaly consistency].freeze

      def initialize(rule_engine:)
        @rule_engine = rule_engine
      end

      def perform(context)
        source_findings = context.prior_results.flat_map(&:findings)
        findings = @rule_engine.recommendations(source_findings, context: context, analyzer_name: name)
        result(findings, metrics: { source_findings: source_findings.length, rules: @rule_engine.rules.length })
      end
    end
  end
end
