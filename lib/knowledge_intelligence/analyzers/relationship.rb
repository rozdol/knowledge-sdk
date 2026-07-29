# frozen_string_literal: true

module KnowledgeIntelligence
  module Analyzers
    class Relationship < Analyzer
      NAME = "relationship"
      VERSION = "1.0.0"

      def perform(context)
        findings = []
        self_id = context.snapshot.self_id
        graph = Projection.social(context.snapshot, as_of: context.as_of)
        bridge_nodes = GraphAlgorithms.bridges(graph).flatten.uniq
        people = context.snapshot.records(type: "person").reject { |person| person.id == self_id }
        people.each do |person|
          strength = context.features.fetch("relationship_strength", subject_id: person.id)
          recency = context.features.fetch("recency_score", subject_id: person.id)
          trust = context.features.fetch("trust_score", subject_id: person.id)
          influence = context.features.fetch("influence_score", subject_id: person.id)
          community = context.features.fetch("community_membership", subject_id: person.id)
          feature_values = {
            relationship_strength: strength.value, recency_score: recency.value,
            trust_score: trust.value, influence_score: influence.value,
            community_membership: community.value
          }
          evidence = strength.evidence
          days = recency.metadata["days_since_interaction"]
          if days && days >= context.config.fetch(:inactive_days, 180)
            findings << finding(
              kind: "inactive_contact", title: "Inactive contact: #{person.name}", entity_ids: [person.id],
              confidence: [1.0 - recency.value, trust.value].max, evidence: evidence,
              explanation: "No substantive interaction with #{person.name} has been recorded for #{days} days. " \
                           "Relationship strength is #{strength.value.round(2)}.",
              severity: strength.value >= 0.55 ? "medium" : "low",
              priority: strength.value >= 0.55 ? "high" : "normal",
              tags: %w[relationship inactive], features: feature_values,
              details: { days_inactive: days }
            )
          end
          if strength.value >= context.config.fetch(:strong_relationship_threshold, 0.7)
            findings << finding(
              kind: "strong_contact", title: "Strong contact: #{person.name}", entity_ids: [person.id],
              confidence: strength.value, evidence: evidence, explanation: strength.explanation,
              tags: %w[relationship strong], features: feature_values
            )
          elsif strength.value <= context.config.fetch(:weak_relationship_threshold, 0.3)
            findings << finding(
              kind: "weak_contact", title: "Weak contact: #{person.name}", entity_ids: [person.id],
              confidence: 1.0 - strength.value, evidence: evidence,
              explanation: "The unified relationship-strength score is #{strength.value.round(2)}. #{strength.explanation}",
              severity: "low", tags: %w[relationship weak], features: feature_values
            )
          end
          if graph.neighbors(person.id).empty?
            findings << finding(
              kind: "isolated_person", title: "Isolated person: #{person.name}", entity_ids: [person.id],
              confidence: 1.0, evidence: [],
              explanation: "#{person.name} has no asserted person-to-person relationship, substantive co-interaction, or introduction edge.",
              severity: "low", tags: %w[network isolated], features: feature_values
            )
          end
          if bridge_nodes.include?(person.id)
            findings << finding(
              kind: "bridge_person", title: "Bridge person: #{person.name}", entity_ids: [person.id],
              confidence: [0.6 + influence.value, 1.0].min, evidence: [],
              explanation: "#{person.name} is an endpoint of a bridge edge whose removal would split part of the social graph.",
              severity: "info", tags: %w[network bridge], features: feature_values
            )
          end
          if influence.metadata["introduction_count"].to_i >= 2 || influence.value >= 0.25
            findings << finding(
              kind: "connector_person", title: "Connector person: #{person.name}", entity_ids: [person.id],
              confidence: [0.55 + influence.value, 1.0].min, evidence: [],
              explanation: "Influence score #{influence.value.round(2)} reflects network centrality and " \
                           "#{influence.metadata['introduction_count']} completed introductions.",
              severity: "info", tags: %w[network connector], features: feature_values
            )
          end
        end
        result(findings, metrics: { people_analyzed: people.length, social_edges: graph.edge_count })
      end
    end
  end
end
