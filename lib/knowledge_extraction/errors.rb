# frozen_string_literal: true

module KnowledgeExtraction
  class Error < StandardError; end
  class UnsupportedSource < Error; end
  class NormalizationFailure < Error; end
  class ProviderFailure < Error; end
  class MalformedStructuredOutput < Error; end
  class FactValidationFailure < Error; end
  class EvidenceMismatch < Error; end
  class EntityResolutionConflict < Error; end
  class PlanningFailure < Error; end
  class UnsupportedIntentMapping < Error; end
  class ApprovalSubmissionFailure < Error; end
  class DuplicateSource < Error; end
  class PrivacyPolicyViolation < Error; end
  class ProposalNotFound < Error; end
end
