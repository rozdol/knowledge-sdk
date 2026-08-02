# frozen_string_literal: true

require_relative "knowledge_analysis/errors"
require_relative "knowledge_analysis/correlation_engine"
require_relative "knowledge_analysis/plugins"
require_relative "knowledge_analysis/decision_adapter"
require_relative "knowledge_analysis/recommendations"
require_relative "knowledge_analysis/engine"
require_relative "knowledge_analysis/cli"

module KnowledgeAnalysis
  VERSION = "1.0.0"

  class << self
    def registry
      @registry ||= PluginRegistry.new.tap do |registry|
        registry.register(Plugins::Health.new)
        registry.register(Plugins::Finance.new)
        registry.register(Plugins::CRM.new)
        registry.register(Plugins::TemplateSemantics.new)
        registry.register(Plugins::Generic.new)
      end
    end
  end
end

KnowledgeAnalysis::IntentClassifierPlugin.register
