# frozen_string_literal: true

module KnowledgeIntelligence
  module Analyzers
    class Consistency < Analyzer
      NAME = "consistency"
      VERSION = "1.0.0"

      def perform(context)
        findings = []
        signatures = Hash.new { |hash, key| hash[key] = [] }
        context.snapshot.relationships(as_of: context.as_of).each do |record|
          signature = [record["subject_id"], record["predicate"], record["object_id"], record["recipient_id"],
                       record["valid_from"], record["valid_to"], record["observed_on"]]
          signatures[signature] << record
        end
        signatures.each_value do |records|
          next unless records.length > 1

          findings << finding(
            kind: "duplicate_relationship_signature", title: "Duplicate relationship signature",
            entity_ids: records.map(&:id), confidence: 1.0,
            evidence: records.map { |record| context.evidence(record) },
            explanation: "#{records.length} asserted relationship records share endpoints, predicate, recipient, and temporal scope.",
            severity: "high", priority: "high", tags: %w[consistency duplicate]
          )
        end
        unresolved_structural(context).each do |record, field, link|
          findings << finding(
            kind: "unresolved_structural_link", title: "Unresolved structural link in #{record.id}",
            entity_ids: [record.id], confidence: 1.0,
            evidence: [context.evidence(record, field: field, value: link)],
            explanation: "The #{field} link #{link.inspect} does not resolve inside the immutable snapshot.",
            severity: "critical", priority: "critical", tags: %w[consistency broken-link]
          )
        end
        result(findings, metrics: { relationship_signatures: signatures.length })
      end

      private

      def unresolved_structural(context)
        fields = %w[participants related_entities organizer place part_of_event introducer person_a person_b
                    promisor promise_to related_to fulfillment_evidence owner with completion_evidence]
        context.snapshot.records.each_with_object([]) do |record, result|
          fields.each do |field|
            Array(record[field]).each do |link|
              next unless link.to_s.start_with?("[[")
              result << [record, field, link] unless context.snapshot.resolve_link(link)
            end
          end
        end
      end
    end
  end
end
