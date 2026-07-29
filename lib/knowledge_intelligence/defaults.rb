# frozen_string_literal: true

module KnowledgeIntelligence
  module DefaultAnalyzers
    module_function

    def build(rule_path: default_rule_path)
      rule_engine = RuleEngine.load(rule_path)
      [
        Analyzers::Relationship.new,
        Analyzers::KnowledgeGap.new,
        Analyzers::Opportunity.new,
        Analyzers::Followup.new,
        Analyzers::Activity.new,
        Analyzers::Project.new,
        Analyzers::Timeline.new,
        Analyzers::Network.new,
        Analyzers::Memory.new,
        Analyzers::Anomaly.new,
        Analyzers::Consistency.new,
        Analyzers::Recommendation.new(rule_engine: rule_engine)
      ].freeze
    end

    def default_rule_path
      File.expand_path("../../config/intelligence_rules.yml", __dir__)
    end
  end
end
