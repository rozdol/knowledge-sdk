# frozen_string_literal: true

module KnowledgeIntelligence
  module Analyzers
    class Timeline < Analyzer
      NAME = "timeline"
      VERSION = "1.0.0"

      def perform(context)
        interactions = context.snapshot.interactions(as_of: context.as_of)
        months = Hash.new { |hash, key| hash[key] = [] }
        interactions.each do |record|
          time = context.snapshot.parse_time(record["starts_at"])
          months[time.strftime("%Y-%m")] << record if time
        end
        counts = months.transform_values(&:length)
        nonzero = counts.values
        average = nonzero.empty? ? 0.0 : nonzero.sum.to_f / nonzero.length
        findings = []
        months.keys.sort.each do |month|
          records = months[month]
          if average.positive? && records.length >= [average * 2.0, 3].max
            findings << finding(
              kind: "activity_burst", title: "Activity burst: #{month}", entity_ids: records.map(&:id),
              confidence: [records.length / (average * 3.0), 1.0].min,
              evidence: records.map { |record| context.evidence(record, field: "starts_at") },
              explanation: "#{records.length} interactions occurred versus a monthly average of #{average.round(1)}.",
              severity: "info", tags: %w[timeline burst], details: { month: month, count: records.length }
            )
          end
        end
        findings.concat(quiet_periods(context, months))
        findings.concat(evolution_findings(context))
        result(findings, metrics: { interaction_count: interactions.length, active_months: months.length })
      end

      private

      def quiet_periods(context, months)
        return [] if months.empty?

        first = Date.strptime(months.keys.min + "-01", "%Y-%m-%d")
        last = Date.new(context.as_of.year, context.as_of.month, 1)
        cursor = first
        empty = []
        while cursor <= last
          key = cursor.strftime("%Y-%m")
          empty << key unless months.key?(key)
          cursor = cursor.next_month
        end
        empty.each_with_object([]) do |month, result|
          result << finding(
            kind: "quiet_period", title: "Quiet period: #{month}", entity_ids: [], confidence: 1.0,
            evidence: [], explanation: "No interaction is recorded in #{month}.",
            severity: "info", tags: %w[timeline quiet], details: { month: month }
          )
        end
      end

      def evolution_findings(context)
        context.snapshot.records(type: "person").reject { |person| person.id == context.snapshot.self_id }.each_with_object([]) do |person, result|
          interactions = context.snapshot.interactions_between(
            context.snapshot.self_id, person.id, as_of: context.as_of, substantive_only: true
          )
          next if interactions.length < 2

          ordered = interactions.sort_by { |record| context.snapshot.parse_time(record["starts_at"]) }
          first_date = context.snapshot.parse_time(ordered.first["starts_at"]).to_date
          last_date = context.snapshot.parse_time(ordered.last["starts_at"]).to_date
          result << finding(
            kind: "relationship_evolution", title: "Relationship timeline: #{person.name}",
            entity_ids: [person.id] + ordered.map(&:id), confidence: 1.0,
            evidence: ordered.map { |record| context.evidence(record, field: "starts_at") },
            explanation: "#{ordered.length} substantive interactions span #{first_date.iso8601} to #{last_date.iso8601}.",
            severity: "info", tags: %w[timeline relationship-evolution],
            details: { first_interaction_on: first_date.iso8601, last_interaction_on: last_date.iso8601,
                       interaction_count: ordered.length }
          )
        end
      end
    end
  end
end
