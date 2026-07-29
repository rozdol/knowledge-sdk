# frozen_string_literal: true

module KnowledgeIntelligence
  module Analyzers
    class KnowledgeGap < Analyzer
      NAME = "knowledge_gap"
      VERSION = "1.0.0"

      LABELS = {
        "email" => "email", "phone" => "phone", "organization" => "company or organization",
        "location" => "location", "interest" => "interest", "relationship" => "relationship"
      }.freeze

      def perform(context)
        findings = []
        people = context.snapshot.records(type: "person").reject { |person| person.id == context.snapshot.self_id }
        people.each do |person|
          completeness = context.features.fetch("completeness_score", subject_id: person.id)
          completeness.metadata["missing"].each do |signal|
            next unless LABELS.key?(signal)

            findings << finding(
              kind: "missing_#{signal}", title: "Missing #{LABELS[signal]}: #{person.name}",
              entity_ids: [person.id], confidence: 1.0,
              evidence: [context.evidence(person, field: "name")],
              explanation: "No canonical #{LABELS[signal]} fact is recorded for #{person.name}. " \
                           "Profile completeness is #{completeness.value.round(2)}.",
              severity: "low", tags: ["knowledge-gap", "missing-#{signal}"],
              features: { completeness_score: completeness.value }, details: { missing_signal: signal }
            )
          end
          uncertain = context.snapshot.relationships(as_of: context.as_of, entity_id: person.id).select do |record|
            %w[possible disputed].include?(record["confidence"])
          end
          unless uncertain.empty?
            findings << finding(
              kind: "low_confidence_identity", title: "Low-confidence facts: #{person.name}",
              entity_ids: [person.id], confidence: 0.7,
              evidence: uncertain.map { |record| context.evidence(record, field: "confidence") },
              explanation: "#{uncertain.length} relationship assertion(s) involving #{person.name} are possible or disputed.",
              severity: "medium", priority: "high", tags: %w[knowledge-gap confidence]
            )
          end
        end
        duplicate_groups(context.snapshot, people).each do |normalized, candidates|
          findings << finding(
            kind: "duplicate_candidate", title: "Possible duplicate identities: #{candidates.map(&:name).join(' / ')}",
            entity_ids: candidates.map(&:id), confidence: 0.35,
            evidence: candidates.map { |person| context.evidence(person, field: "name") },
            explanation: "The records share the normalized name #{normalized.inspect}. Name similarity is only a candidate signal; no merge is proposed.",
            severity: "medium", priority: "high", tags: %w[knowledge-gap duplicate-candidate],
            details: { normalized_name: normalized, requires_human_identity_review: true }
          )
        end
        result(findings, metrics: { people_analyzed: people.length })
      end

      private

      def duplicate_groups(snapshot, people)
        groups = Hash.new { |hash, key| hash[key] = [] }
        people.each do |person|
          ([person.name] + Array(person["aliases"])).compact.each do |name|
            normalized = name.to_s.downcase.gsub(/[^\p{Alnum}]+/u, " ").strip
            groups[normalized] << person unless normalized.empty?
          end
        end
        groups.each_with_object({}) do |(normalized, records), result|
          unique = records.uniq(&:id)
          result[normalized] = unique.sort_by(&:id) if unique.length > 1
        end
      end
    end
  end
end
