# frozen_string_literal: true

module KnowledgeIntelligence
  class Report
    attr_reader :name, :as_of, :summary, :sections, :metrics

    def initialize(name:, as_of:, summary:, sections:, metrics: {})
      @name = name.to_s.freeze
      @as_of = as_of.to_s.freeze
      @summary = summary.to_s.freeze
      @sections = Immutable.copy(sections)
      @metrics = Immutable.copy(metrics)
      freeze
    end

    def to_h
      { name: name, as_of: as_of, summary: summary, sections: sections, metrics: metrics }
    end
  end

  class DigestBuilder
    def initialize(snapshot:, as_of: Date.today)
      @snapshot = snapshot
      @as_of = as_of
    end

    def build(run_result, days: 7)
      cutoff = @as_of - days
      relationships = @snapshot.records(type: "relationship").select do |record|
        asserted = @snapshot.parse_time(record["asserted_at"])
        asserted && asserted.to_date >= cutoff && asserted.to_date <= @as_of
      end
      followups = @snapshot.records(type: "follow-up").select do |record|
        due = @snapshot.parse_date(record["due_on"])
        due && due >= @as_of && due <= @as_of + days && %w[open scheduled waiting].include?(record["followup_status"])
      end
      events = @snapshot.records(type: "event").select do |record|
        starts = @snapshot.parse_time(record["starts_at"])
        starts && starts.to_date >= @as_of && starts.to_date <= @as_of + days
      end
      findings = run_result.findings
      sections = {
        "new_relationships" => relationships.map { |record| record_summary(record) },
        "inactive_contacts" => finding_summaries(findings, %w[inactive_contact]),
        "upcoming_followups" => followups.map { |record| record_summary(record) },
        "knowledge_gaps" => finding_summaries(findings, findings.map(&:kind).select { |kind| kind.start_with?("missing_") }),
        "important_events" => events.map { |record| record_summary(record) },
        "opportunities" => finding_summaries(findings, %w[possible_introduction investor_path customer_path])
      }
      Report.new(
        name: digest_name(days), as_of: @as_of.iso8601,
        summary: "#{sections.values.sum(&:length)} digest items across #{sections.length} sections.",
        sections: sections, metrics: { window_days: days, cutoff: cutoff.iso8601 }
      )
    end

    private

    def digest_name(days)
      return "daily_digest" if days <= 1
      return "weekly_digest" if days <= 7

      "monthly_digest"
    end

    def record_summary(record)
      { id: record.id, type: record.type, name: record.name, path: record.path }
    end

    def finding_summaries(findings, kinds)
      findings.select { |finding| kinds.include?(finding.kind) }.map do |finding|
        { finding_id: finding.finding_id, kind: finding.kind, title: finding.title,
          confidence: finding.confidence, explanation: finding.explanation,
          entity_ids: finding.entity_ids }
      end
    end
  end

  class ReportEngine
    REPORT_ANALYZERS = {
      "relationship_health" => %w[relationship activity],
      "knowledge_gap" => %w[knowledge_gap consistency],
      "opportunity" => %w[opportunity],
      "network" => %w[network],
      "followup" => %w[followup],
      "project" => %w[project activity]
    }.freeze

    def initialize(snapshot:, as_of: Date.today)
      @snapshot = snapshot
      @as_of = as_of
    end

    def build(name, run_result)
      key = name.to_s.tr("-", "_")
      return DigestBuilder.new(snapshot: @snapshot, as_of: @as_of).build(run_result, days: 1) if key == "daily_digest"
      return DigestBuilder.new(snapshot: @snapshot, as_of: @as_of).build(run_result, days: 7) if key == "weekly_digest"
      return DigestBuilder.new(snapshot: @snapshot, as_of: @as_of).build(run_result, days: 30) if key == "monthly_digest"
      return crm_score(run_result) if key == "personal_crm"

      analyzers = REPORT_ANALYZERS[key]
      raise Error, "unknown intelligence report #{name.inspect}" unless analyzers

      selected = run_result.results.select { |result| analyzers.include?(result.analyzer) }
      sections = selected.each_with_object({}) do |result, output|
        output[result.analyzer] = result.findings.map(&:to_h)
      end
      Report.new(
        name: "#{key}_report", as_of: @as_of.iso8601,
        summary: "#{selected.sum { |result| result.findings.length }} findings from #{selected.length} analyzers.",
        sections: sections, metrics: { analyzers: analyzers }
      )
    end

    private

    def crm_score(run_result)
      people = @snapshot.records(type: "person").reject { |record| record.id == @snapshot.self_id }
      if people.empty?
        return Report.new(
          name: "personal_crm_score", as_of: @as_of.iso8601,
          summary: "Personal CRM score is not yet meaningful because no contacts are recorded.",
          sections: { completeness: 0.0, relationship_health: 0.0,
                      followup_health: 0.0, connectivity: 0.0 },
          metrics: { score: 0.0, contact_count: 0,
                     weights: { completeness: 0.4, relationship_health: 0.25,
                                followup_health: 0.2, connectivity: 0.15 } }
        )
      end
      gaps = run_result.findings.count { |finding| finding.kind.start_with?("missing_") }
      overdue = run_result.findings.count { |finding| %w[overdue_followup broken_promise].include?(finding.kind) }
      isolated = run_result.findings.count { |finding| finding.kind == "isolated_person" }
      possible = [people.length * 6, 1].max
      completeness = [[1.0 - gaps.to_f / possible, 0.0].max, 1.0].min
      followup_health = [1.0 - overdue.to_f / [people.length, 1].max, 0.0].max
      connectivity = [1.0 - isolated.to_f / [people.length, 1].max, 0.0].max
      active = run_result.findings.count { |finding| finding.kind == "strong_contact" }
      relationship_health = [active.to_f / people.length + 0.5, 1.0].min
      score = 100.0 * (0.4 * completeness + 0.25 * relationship_health + 0.2 * followup_health + 0.15 * connectivity)
      Report.new(
        name: "personal_crm_score", as_of: @as_of.iso8601,
        summary: "Personal CRM score: #{score.round(1)} / 100.",
        sections: {
          completeness: completeness.round(4), relationship_health: relationship_health.round(4),
          followup_health: followup_health.round(4), connectivity: connectivity.round(4)
        },
        metrics: { score: score.round(2), weights: { completeness: 0.4, relationship_health: 0.25,
                                                     followup_health: 0.2, connectivity: 0.15 } }
      )
    end
  end
end
