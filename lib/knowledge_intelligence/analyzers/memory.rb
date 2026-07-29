# frozen_string_literal: true

module KnowledgeIntelligence
  module Analyzers
    class Memory < Analyzer
      NAME = "memory"
      VERSION = "1.0.0"

      def perform(context)
        target_ids = Array(context.config[:memory_person_ids]).map(&:to_s)
        people = context.snapshot.records(type: "person").reject { |person| person.id == context.snapshot.self_id }
        people = people.select { |person| target_ids.include?(person.id) } unless target_ids.empty?
        findings = people.map { |person| briefing(context, person) }
        result(findings, metrics: { briefing_count: findings.length })
      end

      private

      def briefing(context, person)
        relationships = context.snapshot.relationships(as_of: context.as_of, entity_id: person.id)
        interactions = if context.snapshot.self_id
                         context.snapshot.interactions_between(
                           context.snapshot.self_id, person.id, as_of: context.as_of, substantive_only: true
                         )
                       else
                         []
                       end
        latest = interactions.max_by { |record| context.snapshot.parse_time(record["starts_at"]) }
        facts = relationships.sort_by(&:id).first(12).map do |record|
          other_id = record["subject_id"] == person.id ? record["object_id"] : record["subject_id"]
          other = context.snapshot.record(other_id)
          { predicate: record["predicate"], related_entity_id: other_id, related_name: other&.name,
            confidence: record["confidence"] }
        end
        introductions = context.snapshot.introductions_for(person.id)
        strength = context.features.fetch("relationship_strength", subject_id: person.id)
        explanation = "Briefing for #{person.name}: #{facts.length} current relationship facts, " \
                      "#{introductions.length} introductions, and relationship strength #{strength.value.round(2)}."
        if latest
          last_date = context.snapshot.parse_time(latest["starts_at"]).to_date
          explanation += " Last substantive interaction: #{last_date.iso8601}."
        end
        finding(
          kind: "briefing_card", title: "Briefing: #{person.name}", entity_ids: [person.id],
          confidence: facts.empty? ? 0.55 : 0.9,
          evidence: relationships.map { |record| context.evidence(record) } +
                    interactions.map { |record| context.evidence(record, field: "starts_at") } +
                    introductions.map { |record| context.evidence(record) },
          explanation: explanation, severity: "info", tags: %w[memory briefing],
          features: { relationship_strength: strength.value },
          details: { relationship_facts: facts, introduction_count: introductions.length,
                     latest_interaction_id: latest&.id }
        )
      end
    end
  end
end
