# frozen_string_literal: true

module KnowledgeGraph
  class Error < StandardError; end
  class InvalidIntent < Error; end
  class UnsupportedIntent < Error; end
  class ValidationError < Error; end
  class SchemaError < Error; end
  class EntityNotFound < Error; end
  class EntityConflict < Error; end
  class ApprovalRequired < Error; end
  class IdentityConflict < Error; end
  class RelationshipConflict < Error; end
  class TransactionError < Error; end
  class AuditError < Error; end
end
