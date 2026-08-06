# frozen_string_literal: true

module KnowledgeCapture
  class Error < StandardError; end
  class InvalidCapture < Error; end
  class CaptureNotFound < Error; end
  class AmbiguousCapture < Error; end
  class InvalidTransition < Error; end
  class PluginError < Error; end
  class PromotionError < Error; end
end
