# frozen_string_literal: true

module KnowledgeIntelligence
  module Analyzers
    class Followup < Analyzer
      NAME = "followup"
      VERSION = "1.0.0"

      def perform(context)
        findings = []
        open_followups = context.snapshot.records(type: "follow-up").select do |record|
          %w[open scheduled waiting snoozed].include?(record["followup_status"])
        end
        open_followups.each do |record|
          due = due_date(context.snapshot, record)
          if due && due < context.as_of
            days = (context.as_of - due).to_i
            findings << finding(
              kind: "overdue_followup", title: "Overdue follow-up: #{record.name}", entity_ids: [record.id],
              confidence: 1.0, evidence: [context.evidence(record, field: "due_on")],
              explanation: "The follow-up is #{days} days overdue and remains #{record['followup_status']}.",
              severity: days >= 30 ? "high" : "medium", priority: days >= 14 ? "critical" : "high",
              tags: %w[followup overdue], details: { days_overdue: days, action: record["action"] }
            )
          elsif !due
            created = context.snapshot.parse_time(record["created_at"])
            age = created && (context.as_of - created.to_date).to_i
            if age && age >= context.config.fetch(:forgotten_task_days, 30)
              findings << finding(
                kind: "forgotten_task", title: "Undated follow-up: #{record.name}", entity_ids: [record.id],
                confidence: 0.9, evidence: [context.evidence(record, field: "created_at")],
                explanation: "The follow-up has remained open without a due date for #{age} days.",
                severity: "medium", priority: "high", tags: %w[followup forgotten],
                details: { age_days: age, action: record["action"] }
              )
            end
          end
        end
        context.snapshot.records(type: "commitment").each do |record|
          next unless %w[open overdue].include?(record["commitment_status"])

          due = due_date(context.snapshot, record)
          next unless due && due < context.as_of

          days = (context.as_of - due).to_i
          item = finding(
            kind: "broken_promise", title: "Unfulfilled commitment: #{record.name}", entity_ids: [record.id],
            confidence: 1.0, evidence: [context.evidence(record, field: "due_on")],
            explanation: "The commitment remains #{record['commitment_status']} #{days} days after its due date.",
            severity: days >= 30 ? "critical" : "high", priority: "critical",
            tags: %w[commitment overdue broken-promise], details: { days_overdue: days, action: record["action"] }
          )
          proposal = followup_proposal(context, record, item)
          findings << item.with_proposals([proposal])
        end
        findings.concat(missing_outcomes(context))
        result(findings, metrics: { open_followups: open_followups.length })
      end

      private

      def due_date(snapshot, record)
        value = record["due_on"] || (record["followup_status"] == "snoozed" && record["snoozed_until"])
        value && snapshot.parse_date(value, boundary: :end)
      end

      def followup_proposal(context, commitment, source_finding)
        owner = context.snapshot.resolve_link(commitment["promisor"])
        recipient = context.snapshot.resolve_link(commitment["promise_to"])
        owner_record = context.snapshot.record(owner)
        recipient_record = context.snapshot.record(recipient)
        attributes = {
          "name" => "Follow up: #{commitment['action']}", "aliases" => [],
          "owner" => wikilink(owner_record), "action" => commitment["action"],
          "followup_status" => "open", "with" => [wikilink(recipient_record)].compact,
          "priority" => "high", "sensitivity" => commitment["sensitivity"] || "private",
          "data_origin" => "inferred", "related_to" => [wikilink(commitment)].compact
        }.reject { |_key, value| value.nil? }
        IntentProposal.new(
          intent: { "type" => "CreateEntity", "params" => { "entity_type" => "follow-up", "attributes" => attributes } },
          finding_id: source_finding.finding_id, evidence_ids: source_finding.evidence.map(&:evidence_id),
          planning_confidence: source_finding.confidence, risk: "medium", approval_requirement: "human_review",
          blocked_reasons: owner_record ? [] : ["commitment promisor could not be resolved"]
        )
      end

      def wikilink(record)
        record && "[[#{record.path.sub(/\.md\z/, '')}|#{record.name || record.id}]]"
      end

      def missing_outcomes(context)
        cutoff = context.as_of - context.config.fetch(:meeting_outcome_review_days, 7)
        linked_paths = context.snapshot.records(type: "follow-up").flat_map { |record| Array(record["related_to"]) } +
                       context.snapshot.records(type: "commitment").flat_map { |record| Array(record["related_to"]) }
        context.snapshot.interactions(as_of: context.as_of, substantive_only: true).each_with_object([]) do |record, result|
          starts = context.snapshot.parse_time(record["starts_at"])
          next unless starts && starts.to_date <= cutoff
          link_target = record.path.sub(/\.md\z/, "")
          next if linked_paths.any? { |link| link.to_s.include?("[[#{link_target}|") || link.to_s == "[[#{link_target}]]" }

          result << finding(
            kind: "missing_meeting_outcome", title: "No structured outcome: #{record.name}", entity_ids: [record.id],
            confidence: 0.65, evidence: [context.evidence(record, field: "starts_at")],
            explanation: "No Follow-up or Commitment links back to this substantive interaction.",
            severity: "low", tags: %w[followup meeting-outcome]
          )
        end
      end
    end
  end
end
