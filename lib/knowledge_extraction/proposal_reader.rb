# frozen_string_literal: true

require "json"
require "pathname"

module KnowledgeExtraction
  # Shared format/ID validation; this module has no writer or approval operation.
  module ProposalReadOperations
    def load(proposal_id)
      path = proposal_path(proposal_id)
      raise ProposalNotFound, "proposal not found: #{proposal_id}" unless path.file?

      JSON.parse(path.read)
    rescue JSON::ParserError => error
      raise PlanningFailure, "stored proposal is invalid JSON: #{error.message}"
    end

    def submissions
      directory = @root.join("submissions")
      return [] unless directory.directory?

      Dir[directory.join("proposal_*.json").to_s].sort.map do |path|
        JSON.parse(File.read(path))
      rescue JSON::ParserError => error
        raise ApprovalSubmissionFailure, "submission receipt is invalid: #{error.message}"
      end.freeze
    end

    def approval(proposal_id)
      path = approval_path(proposal_id)
      return nil unless path.file?

      JSON.parse(path.read)
    rescue JSON::ParserError => error
      raise ApprovalSubmissionFailure, "approval receipt is invalid: #{error.message}"
    end

    private

    def proposal_path(proposal_id)
      @root.join("proposals", "#{safe_id(proposal_id, 'proposal')}.json")
    end

    def approval_path(proposal_id)
      @root.join("approvals", "#{safe_id(proposal_id, 'proposal')}.json")
    end

    def safe_id(value, label)
      string = value.to_s
      unless string.match?(/\A[a-z][a-z0-9-]*_[0-9A-HJKMNP-TV-Z]{26}\z/)
        raise PlanningFailure, "invalid #{label} ID"
      end

      string
    end
  end

  class ProposalReader
    include ProposalReadOperations

    def initialize(vault_root:)
      @root = Pathname.new(vault_root).expand_path.join("#{KnowledgeSDK::RUNTIME_PATH}/extraction")
    end
  end
end
