# frozen_string_literal: true

module KnowledgeActivity
  class Error < KnowledgeGraph::Error; end
  class ActivityNotFound < Error; end
  class InvalidActivityQuery < Error; end
  class ReversalUnavailable < Error; end
end
