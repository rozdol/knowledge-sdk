# frozen_string_literal: true

module KnowledgeAnalysis
  class Error < StandardError; end
  class InvalidAnalysis < Error; end
  class UnsupportedAnalysis < Error; end
  class RecommendationError < Error; end
end
