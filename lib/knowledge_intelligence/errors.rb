# frozen_string_literal: true

module KnowledgeIntelligence
  class Error < StandardError; end
  class UnknownFeature < Error; end
  class FeatureCycle < Error; end
  class InvalidFeatureRequest < Error; end
  class UnknownAnalyzer < Error; end
  class InvalidQuery < Error; end
  class ReadOnlyViolation < Error; end
end
