# frozen_string_literal: true

module KnowledgeIntelligence
  module Analyzers
    class Project < Analyzer
      NAME = "project"
      VERSION = "1.0.0"

      def perform(context)
        findings = []
        projects = context.snapshot.records(type: "project").select do |record|
          %w[active planned paused].include?(record["project_status"])
        end
        projects.each do |project|
          related = context.snapshot.records_referencing(
            project.id, type: "interaction", fields: ["related_entities"]
          ).select do |interaction|
            starts = context.snapshot.parse_time(interaction["starts_at"])
            starts && starts.to_date <= context.as_of
          end
          last = related.map { |record| context.snapshot.parse_time(record["starts_at"]) }.compact.max
          baseline = last&.to_date || context.snapshot.parse_date(project["started_on"]) ||
                     context.snapshot.parse_time(project["created_at"])&.to_date
          next unless baseline

          days = (context.as_of - baseline).to_i
          threshold = context.config.fetch(:stale_project_days, 90)
          next unless days >= threshold

          completeness = context.features.fetch("completeness_score", subject_id: project.id)
          findings << finding(
            kind: "stale_project", title: "Stale project: #{project.name}", entity_ids: [project.id],
            confidence: [days.to_f / (threshold * 2), 1.0].min,
            evidence: [context.evidence(project, field: "project_status")] +
                      related.map { |record| context.evidence(record, field: "starts_at") },
            explanation: "The #{project['project_status']} project has no recorded activity for #{days} days.",
            severity: project["project_status"] == "active" ? "medium" : "low",
            priority: project["project_status"] == "active" ? "high" : "normal",
            tags: %w[project stale], features: { completeness_score: completeness.value },
            details: { days_inactive: days, project_status: project["project_status"] }
          )
        end
        result(findings, metrics: { projects_analyzed: projects.length })
      end
    end
  end
end
