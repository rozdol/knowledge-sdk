# frozen_string_literal: true

module AgentPlatform
  class Error < StandardError
    attr_reader :details

    def initialize(message = nil, details: {})
      super(message)
      @details = Value.immutable(details || {})
    end

    def code
      self.class.name.split("::").last
    end
  end

  class CapabilityNotFound < Error; end
  class PolicyDenied < Error; end
  class ApprovalRequired < Error; end
  class InvalidArguments < Error; end
  class InvalidRequest < Error; end
  class InvalidManifest < Error; end
  class IncompatibleVersion < Error; end
  class HandlerNotRegistered < Error; end
  class SessionExpired < Error; end
  class SessionNotFound < Error; end
  class ProposalNotFound < Error; end
  class ExecutionFailed < Error; end
  class OutputValidationFailed < Error; end
  class Timeout < Error; end
  class UnsupportedCapability < Error; end
  class SecurityViolation < Error; end
  class JobNotFound < Error; end
end
