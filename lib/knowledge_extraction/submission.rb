# frozen_string_literal: true

module KnowledgeExtraction
  class ProposalSubmitter
    def initialize(engine:, store:, clock: nil, dataset_engine: nil)
      @engine = engine
      @store = store
      @clock = clock || -> { Time.now }
      @dataset_engine = dataset_engine
    end

    def submit(proposal_id, dry_run: false)
      proposal = @store.load(proposal_id)
      ProposalValidator.new.validate!(proposal)
      approval = @store.approval(proposal_id)
      verify_approval!(proposal, approval)
      approved_ids = approval ? approval.fetch("approved_intent_ids") : []
      ordered = topological_order(proposal.fetch("planned_intents"))
      results = []
      completed = {}
      failed = false
      ordered.each do |item|
        reasons = item.fetch("blocked_reasons", []).dup
        reasons << "a dependency did not execute" unless item.fetch("dependencies", []).all? { |id| completed[id] }
        requirement = item.fetch("approval_requirement")
        if requirement != "none" && !approved_ids.include?(item.fetch("planned_intent_id"))
          reasons << "required human approval is absent"
        end
        reasons << "submission stopped after a prior failure" if failed
        if !reasons.empty? || dry_run
          results << {
            "planned_intent_id" => item.fetch("planned_intent_id"),
            "status" => dry_run && reasons.empty? ? "dry_run" : "blocked",
            "reasons" => reasons
          }
          next
        end

        begin
          intent = approved_intent(item, approved_ids)
          result = execute_intent(intent, proposal_id, approval)
          completed[item.fetch("planned_intent_id")] = true
          results << {
            "planned_intent_id" => item.fetch("planned_intent_id"), "status" => "executed",
            "intent_type" => result.fetch("intent_type"), "entity_ids" => result.fetch("entity_ids"),
            "audit_id" => result.fetch("audit_id"), "replayed" => result.fetch("replayed")
          }.merge(result.fetch("extra", {}))
        rescue StandardError => error
          failed = true
          results << {
            "planned_intent_id" => item.fetch("planned_intent_id"), "status" => "failed",
            "error_class" => error.class.name, "error" => error.message
          }
        end
      end
      status = submission_status(results, dry_run)
      submission = {
        "proposal_id" => proposal_id, "status" => status, "dry_run" => !!dry_run,
        "submitted_at" => @clock.call.iso8601, "results" => results,
        "transaction_semantics" => "dependency-ordered single-Intent Engine transactions; later groups stop after failure"
      }
      @store.save_submission(proposal_id, submission) unless dry_run
      submission
    end

    private

    def execute_intent(intent, proposal_id, approval)
      if intent.is_a?(KnowledgeGraph::InsertDatasetRow)
        row = dataset_engine.insert(
          intent.dataset, intent.values,
          source: intent.source, observation_id: intent.observation_id,
          proposal_id: proposal_id, approval_id: approval && approval["approval_id"],
          created_by: approval && approval["actor_id"] || "proposal-engine",
          intent_id: intent.intent_id
        )
        dataset_id = dataset_engine.describe(intent.dataset).fetch("dataset_id")
        return {
          "intent_type" => intent.intent_type, "entity_ids" => [dataset_id],
          "audit_id" => row.fetch("dataset_activity_id"), "replayed" => row.fetch("replayed"),
          "extra" => { "row_id" => row.fetch("row_id") }
        }
      end

      result = @engine.execute(intent)
      {
        "intent_type" => result.intent_type, "entity_ids" => result.entity_ids,
        "audit_id" => result.audit_id, "replayed" => result.replayed
      }
    end

    def dataset_engine
      @dataset_engine ||= StructuredDataset::Engine.new(
        vault_root: @engine.vault_root, run_id: @engine.run_id,
        actor_id: "proposal-engine", clock: @clock
      )
    end

    def verify_approval!(proposal, approval)
      return unless approval
      expected = @store.proposal_fingerprint(proposal)
      unless approval.fetch("proposal_fingerprint") == expected
        raise ApprovalSubmissionFailure, "approval does not match the immutable proposal"
      end
    end

    def approved_intent(item, approved_ids)
      payload = Marshal.load(Marshal.dump(item.fetch("intent")))
      type = payload.fetch("type")
      params = payload.fetch("params")
      gated = type == "MergeEntities" || type == "SplitEntity" ||
              (type == "CreateEntity" && KnowledgeGraph::EntityManager::APPROVAL_GATED_TYPES.include?(params["entity_type"]))
      params["human_approved"] = true if gated && approved_ids.include?(item.fetch("planned_intent_id"))
      KnowledgeGraph::IntentFactory.build(payload)
    end

    def topological_order(items)
      by_id = items.to_h { |item| [item.fetch("planned_intent_id"), item] }
      ordered = []
      remaining = by_id.keys.sort
      until remaining.empty?
        ready = remaining.select do |id|
          by_id.fetch(id).fetch("dependencies", []).all? { |dependency| ordered.any? { |item| item.fetch("planned_intent_id") == dependency } }
        end
        raise ApprovalSubmissionFailure, "proposal dependency graph is cyclic" if ready.empty?

        ready.each do |id|
          ordered << by_id.fetch(id)
          remaining.delete(id)
        end
      end
      ordered
    end

    def submission_status(results, dry_run)
      return "planned" if dry_run
      statuses = results.map { |result| result.fetch("status") }
      return "executed" if !statuses.empty? && statuses.all? { |status| status == "executed" }
      return "failed" if statuses.include?("failed") && !statuses.include?("executed")

      "partially_rejected"
    end
  end
end
