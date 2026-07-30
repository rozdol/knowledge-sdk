# frozen_string_literal: true

module KnowledgeOrchestration
  class Error < StandardError; end
  class InvalidEvent < Error; end
  class EventNotFound < Error; end
  class UnsupportedEventVersion < Error; end
  class InvalidWorkflow < Error; end
  class WorkflowNotFound < Error; end
  class WorkflowExecutionFailed < Error; end
  class WorkflowCancelled < Error; end
  class JobNotFound < Error; end
  class ScheduleNotFound < Error; end
  class InvalidSchedule < Error; end
  class CacheError < Error; end
  class PluginError < Error; end
end
