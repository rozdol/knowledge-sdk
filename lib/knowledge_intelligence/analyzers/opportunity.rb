# frozen_string_literal: true

module KnowledgeIntelligence
  module Analyzers
    class Opportunity < Analyzer
      NAME = "opportunity"
      VERSION = "1.0.0"

      SHARED_PREDICATES = %w[
        likes interested_in expert_in works_for member_of founded leads contributes_to
        advisor_to invested_in client_of collaborates_with
      ].freeze

      def perform(context)
        findings = []
        self_id = context.snapshot.self_id
        people = context.snapshot.records(type: "person").reject { |person| person.id == self_id }
        graph = Projection.social(context.snapshot, as_of: context.as_of)
        affiliations = people.each_with_object({}) do |person, result|
          result[person.id] = affiliations_for(context, person.id)
        end
        pairs, skipped_affiliations = candidate_pairs(
          affiliations, maximum_members: context.config.fetch(:opportunity_max_affiliation_members, 500)
        )
        people_by_id = people.each_with_object({}) { |person, result| result[person.id] = person }
        pairs.keys.sort.each do |pair|
          first = people_by_id.fetch(pair[0])
          second = people_by_id.fetch(pair[1])
          next if graph.neighbors(first.id).include?(second.id)

          shared = pairs.fetch(pair)

          first_strength = context.features.fetch("relationship_strength", subject_id: first.id)
          second_strength = context.features.fetch("relationship_strength", subject_id: second.id)
          next if [first_strength.value, second_strength.value].min < context.config.fetch(:opportunity_min_strength, 0.2)

          labels = shared.map { |id| context.snapshot.record(id)&.name || id }
          evidence_records = shared.flat_map do |id|
            affiliations[first.id][id] + affiliations[second.id][id]
          end
          kind = collaboration_kind(context.snapshot, shared)
          findings << finding(
            kind: "possible_introduction", title: "Possible introduction: #{first.name} ↔ #{second.name}",
            entity_ids: [first.id, second.id] + shared, confidence: opportunity_confidence(shared.length, first_strength, second_strength),
            evidence: evidence_records.map { |record| context.evidence(record) },
            explanation: "#{first.name} and #{second.name} are not directly connected and share #{labels.join(', ')}. " \
                         "Your relationship-strength scores are #{first_strength.value.round(2)} and #{second_strength.value.round(2)}.",
            severity: "info", priority: shared.length >= 2 ? "high" : "normal",
            tags: ["opportunity", "introduction", kind], graph_path: [first.id, self_id, second.id].compact,
            features: { first_relationship_strength: first_strength.value,
                        second_relationship_strength: second_strength.value },
            details: { shared_entity_ids: shared, shared_labels: labels, opportunity_kind: kind }
          )
        end
        findings.concat(path_findings(context, people, graph, self_id)) if self_id
        result(findings, metrics: { people_analyzed: people.length, candidate_pairs: pairs.length,
                                   skipped_large_affiliations: skipped_affiliations })
      end

      private

      def affiliations_for(context, person_id)
        result = Hash.new { |hash, key| hash[key] = [] }
        context.snapshot.relationships(as_of: context.as_of, entity_id: person_id).each do |record|
          next unless SHARED_PREDICATES.include?(record["predicate"])

          other = record["subject_id"] == person_id ? record["object_id"] : record["subject_id"]
          result[other] << record
        end
        result
      end

      def candidate_pairs(affiliations, maximum_members:)
        members_by_affiliation = Hash.new { |hash, key| hash[key] = [] }
        affiliations.each do |person_id, items|
          items.each_key { |affiliation_id| members_by_affiliation[affiliation_id] << person_id }
        end
        pairs = Hash.new { |hash, key| hash[key] = [] }
        skipped = 0
        members_by_affiliation.keys.sort.each do |affiliation_id|
          members = members_by_affiliation[affiliation_id].uniq.sort
          if members.length > maximum_members
            skipped += 1
            next
          end
          members.combination(2) { |pair| pairs[pair.freeze] << affiliation_id }
        end
        pairs.each_value { |shared| shared.replace(shared.uniq.sort) }
        [pairs, skipped]
      end

      def collaboration_kind(snapshot, ids)
        types = ids.map { |id| snapshot.record(id)&.type }
        return "common-project" if types.include?("project")
        return "common-company" if types.include?("organization")

        "shared-interest"
      end

      def opportunity_confidence(shared_count, first_strength, second_strength)
        base = 0.35 + [shared_count, 3].min * 0.1
        [base + [first_strength.value, second_strength.value].min * 0.25, 0.95].min
      end

      def path_findings(context, people, graph, self_id)
        findings = []
        people.each do |person|
          investor_edges = context.snapshot.relationships(as_of: context.as_of, entity_id: person.id, predicates: ["invested_in"])
          customer_edges = context.snapshot.relationships(as_of: context.as_of, entity_id: person.id, predicates: ["client_of"])
          next if investor_edges.empty? && customer_edges.empty?

          distance = context.features.fetch("graph_distance", subject_id: self_id, object_id: person.id)
          next unless distance.value && distance.value <= 3

          [["investor_path", investor_edges], ["customer_path", customer_edges]].each do |kind, edges|
            next if edges.empty?

            targets = edges.map { |edge| edge["object_id"] }.uniq
            findings << finding(
              kind: kind, title: "#{kind.tr('_', ' ').capitalize} through #{person.name}",
              entity_ids: [person.id] + targets, confidence: [0.55 + 0.1 * (3 - distance.value), 0.85].min,
              evidence: distance.evidence + edges.map { |edge| context.evidence(edge) },
              explanation: "#{person.name} is #{distance.value} social hop(s) away and has #{edges.length} asserted #{kind.sub('_path', '')} edge(s).",
              severity: "info", tags: ["opportunity", kind], graph_path: distance.metadata["path"],
              features: { graph_distance: distance.value }
            )
          end
        end
        findings
      end
    end
  end
end
