# frozen_string_literal: true

module KnowledgeIntelligence
  module Analyzers
    class Anomaly < Analyzer
      NAME = "anomaly"
      VERSION = "1.0.0"

      def perform(context)
        grouped = Hash.new { |hash, key| hash[key] = [] }
        context.snapshot.relationships(as_of: context.as_of).each do |record|
          grouped[[record["subject_id"], record["object_id"]].sort] << record
        end
        findings = []
        grouped.each do |pair, records|
          predicates = records.map { |record| record["predicate"] }
          if predicates.include?("likes") && predicates.include?("dislikes")
            findings << finding(
              kind: "contradictory_preference", title: "Contradictory preference assertion",
              entity_ids: pair, confidence: 0.95,
              evidence: records.select { |record| %w[likes dislikes].include?(record["predicate"]) }.map { |record| context.evidence(record) },
              explanation: "The same entity pair has current asserted likes and dislikes edges.",
              severity: "high", priority: "high", tags: %w[anomaly contradiction]
            )
          end
        end
        primary_residences(context).each do |person_id, records|
          next unless records.length > 1

          findings << finding(
            kind: "multiple_primary_residences", title: "Multiple primary residences: #{context.person_name(person_id)}",
            entity_ids: [person_id] + records.map { |record| record["object_id"] }, confidence: 1.0,
            evidence: records.map { |record| context.evidence(record, field: "residence_kind") },
            explanation: "#{records.length} current lives_in relationships are marked primary.",
            severity: "high", priority: "high", tags: %w[anomaly cardinality]
          )
        end
        result(findings, metrics: { relationship_pairs: grouped.length })
      end

      private

      def primary_residences(context)
        context.snapshot.relationships(as_of: context.as_of, predicates: ["lives_in"]).select do |record|
          record["residence_kind"] == "primary"
        end.group_by { |record| record["subject_id"] }
      end
    end
  end
end
