# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "tempfile"
require "time"

module KnowledgeExtraction
  class ProposalStore
    RUNTIME = "_System/KnowledgeGraph/Runtime/extraction".freeze

    def initialize(vault_root:, clock: nil)
      @root = Pathname.new(vault_root).join(RUNTIME)
      @clock = clock || -> { Time.now }
    end

    def save(proposal)
      payload = proposal.respond_to?(:canonical_json) ? proposal.canonical_json : JSON.pretty_generate(proposal) + "\n"
      path = proposal_path(proposal.respond_to?(:proposal_id) ? proposal.proposal_id : proposal.fetch("proposal_id"))
      if path.file?
        existing = path.read
        raise PlanningFailure, "proposal ID collision with different content" unless existing == payload
        return path
      end
      atomic_write(path, payload)
      path
    end

    def load(proposal_id)
      path = proposal_path(proposal_id)
      raise ProposalNotFound, "proposal not found: #{proposal_id}" unless path.file?

      JSON.parse(path.read)
    rescue JSON::ParserError => error
      raise PlanningFailure, "stored proposal is invalid JSON: #{error.message}"
    end

    def path_for(proposal_id)
      proposal_path(proposal_id)
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

    def submission(proposal_id)
      path = submission_path(proposal_id)
      return nil unless path.file?

      JSON.parse(path.read)
    rescue JSON::ParserError => error
      raise ApprovalSubmissionFailure, "submission receipt is invalid: #{error.message}"
    end

    def classify_source(document)
      entries = source_entries
      same_id = entries.select { |entry| entry["source_id"] == document.source_id }
      return "exact_duplicate" if same_id.any? { |entry| entry["content_hash"] == document.content_hash }
      return "revision" unless same_id.empty?
      return "exact_content_duplicate" if entries.any? { |entry| entry["content_hash"] == document.content_hash }

      "new"
    end

    def record_source(document, proposal_id)
      path = @root.join("sources.json")
      with_lock("sources") do
        entries = source_entries
        signature = [document.source_id, document.content_hash, proposal_id]
        unless entries.any? { |entry| [entry["source_id"], entry["content_hash"], entry["proposal_id"]] == signature }
          entries << {
            "source_id" => document.source_id, "content_hash" => document.content_hash,
            "external_id" => document.external_id, "source_uri" => document.source_uri,
            "proposal_id" => proposal_id, "recorded_at" => @clock.call.iso8601
          }
          atomic_write(path, JSON.pretty_generate(entries.sort_by { |entry| [entry["source_id"], entry["content_hash"]] }) + "\n")
        end
      end
      path
    end

    def approve(proposal_id:, intent_ids:, actor_id:)
      proposal = load(proposal_id)
      known = Array(proposal.fetch("planned_intents")).map { |item| item.fetch("planned_intent_id") }
      requested = Array(intent_ids).map(&:to_s).uniq
      unknown = requested - known
      raise ApprovalSubmissionFailure, "unknown planned Intent IDs: #{unknown.join(', ')}" unless unknown.empty?
      raise ApprovalSubmissionFailure, "actor_id is required" if actor_id.to_s.strip.empty?

      approved_at = @clock.call.iso8601
      receipt = {
        "approval_id" => Support.stable_id("approval", proposal_id, proposal_fingerprint(proposal), actor_id, approved_at),
        "proposal_id" => proposal_id, "proposal_fingerprint" => proposal_fingerprint(proposal),
        "approved_intent_ids" => requested.sort, "actor_id" => actor_id.to_s,
        "approved_at" => approved_at
      }
      atomic_write(approval_path(proposal_id), JSON.pretty_generate(receipt) + "\n")
      receipt
    end

    def approval(proposal_id)
      path = approval_path(proposal_id)
      return nil unless path.file?

      JSON.parse(path.read)
    rescue JSON::ParserError => error
      raise ApprovalSubmissionFailure, "approval receipt is invalid: #{error.message}"
    end

    def save_submission(proposal_id, submission)
      atomic_write(submission_path(proposal_id), JSON.pretty_generate(submission) + "\n")
    end

    def proposal_fingerprint(proposal)
      Digest::SHA256.hexdigest(Support.canonical_json(proposal))
    end

    private

    def source_entries
      path = @root.join("sources.json")
      return [] unless path.file?

      JSON.parse(path.read)
    rescue JSON::ParserError => error
      raise PlanningFailure, "source registry is invalid: #{error.message}"
    end

    def proposal_path(proposal_id)
      @root.join("proposals", "#{safe_id(proposal_id, 'proposal')}.json")
    end

    def approval_path(proposal_id)
      @root.join("approvals", "#{safe_id(proposal_id, 'proposal')}.json")
    end

    def submission_path(proposal_id)
      @root.join("submissions", "#{safe_id(proposal_id, 'proposal')}.json")
    end

    def safe_id(value, label)
      string = value.to_s
      unless string.match?(/\A[a-z][a-z0-9-]*_[0-9A-HJKMNP-TV-Z]{26}\z/)
        raise PlanningFailure, "invalid #{label} ID"
      end

      string
    end

    def atomic_write(path, content)
      FileUtils.mkdir_p(path.dirname)
      Tempfile.create([".#{path.basename}", ".tmp"], path.dirname.to_s) do |file|
        file.write(content)
        file.flush
        file.fsync
        file.close
        File.rename(file.path, path.to_s)
      end
      path
    end

    def with_lock(name)
      FileUtils.mkdir_p(@root)
      lock_path = @root.join(".#{name}.lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    end
  end

  class ProposalValidator
    REQUIRED_FIELDS = %w[
      proposal_id source facts entity_mentions resolution_decisions planned_intents required_approvals
      prompt_version pipeline_version created_at status ingestion_state
    ].freeze

    def validate!(proposal)
      missing = REQUIRED_FIELDS.reject { |field| proposal.key?(field) }
      raise PlanningFailure, "proposal missing fields: #{missing.join(', ')}" unless missing.empty?

      source = proposal.fetch("source")
      raise PlanningFailure, "proposal source must be an object" unless source.is_a?(Hash)
      fact_ids = proposal.fetch("facts").map { |fact| fact.fetch("fact_id") }
      evidence_ids = proposal.fetch("facts").flat_map do |fact|
        fact.fetch("evidence").map { |evidence| evidence.fetch("evidence_id") }
      end
      intents = proposal.fetch("planned_intents")
      ids = intents.map { |item| item.fetch("planned_intent_id") }
      raise PlanningFailure, "duplicate planned Intent IDs" unless ids.uniq.length == ids.length

      intents.each do |item|
        unknown_facts = item.fetch("fact_ids") - fact_ids
        unknown_evidence = item.fetch("evidence_ids") - evidence_ids
        raise PlanningFailure, "planned Intent references unknown facts" unless unknown_facts.empty?
        raise PlanningFailure, "planned Intent references unknown evidence" unless unknown_evidence.empty?
        missing_dependencies = item.fetch("dependencies", []) - ids
        raise PlanningFailure, "planned Intent has unknown dependencies" unless missing_dependencies.empty?
        provenance = item.fetch("provenance")
        unless provenance.fetch("source_id") == source.fetch("source_id")
          raise PlanningFailure, "planned Intent source provenance mismatch"
        end
        KnowledgeGraph::IntentFactory.build(item.fetch("intent"))
      end
      true
    end
  end
end
