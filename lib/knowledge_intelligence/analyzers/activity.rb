# frozen_string_literal: true

module KnowledgeIntelligence
  module Analyzers
    class Activity < Analyzer
      NAME = "activity"
      VERSION = "1.0.0"

      def perform(context)
        findings = []
        people = context.snapshot.records(type: "person").reject { |person| person.id == context.snapshot.self_id }
        people.each do |person|
          frequency = context.features.fetch("interaction_frequency", subject_id: person.id)
          recency = context.features.fetch("recency_score", subject_id: person.id)
          next unless frequency.value.zero? || recency.value < 0.25

          findings << finding(
            kind: "inactive_relationship", title: "Low communication activity: #{person.name}", entity_ids: [person.id],
            confidence: 1.0 - [frequency.value, recency.value].max,
            evidence: frequency.evidence + recency.evidence,
            explanation: "Interaction frequency is #{frequency.value.round(2)} and recency is #{recency.value.round(2)}.",
            severity: "low", tags: %w[activity relationship],
            features: { interaction_frequency: frequency.value, recency_score: recency.value }
          )
        end
        context.snapshot.records(type: "organization").each do |organization|
          dates = related_activity_dates(context, organization.id)
          last = dates.max
          next unless last && (context.as_of - last).to_i >= context.config.fetch(:inactive_company_days, 365)

          findings << finding(
            kind: "inactive_company", title: "Inactive organization: #{organization.name}", entity_ids: [organization.id],
            confidence: 0.85, evidence: [context.evidence(organization, field: "name")],
            explanation: "No related interaction or assertion has been observed for #{(context.as_of - last).to_i} days.",
            severity: "low", tags: %w[activity organization], details: { last_activity_on: last.iso8601 }
          )
        end
        result(findings, metrics: { people_analyzed: people.length })
      end

      private

      def related_activity_dates(context, entity_id)
        relationships = context.snapshot.relationships(as_of: context.as_of, entity_id: entity_id)
        relationship_dates = relationships.map do |record|
          context.snapshot.parse_time(record["asserted_at"])&.to_date || context.snapshot.parse_date(record["observed_on"])
        end
        linked = context.snapshot.records_referencing(
          entity_id, type: "interaction", fields: ["related_entities"]
        ).select do |record|
          starts = context.snapshot.parse_time(record["starts_at"])
          starts && starts.to_date <= context.as_of
        end
        relationship_dates.compact + linked.map { |record| context.snapshot.parse_time(record["starts_at"])&.to_date }.compact
      end
    end
  end
end
