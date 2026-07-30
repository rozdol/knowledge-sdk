# frozen_string_literal: true

module KnowledgePlanning
  class PlanSimulator
    MEETING_ACTIONS = %w[meeting interview attend_event].freeze
    INTRODUCTION_ACTIONS = %w[request_introduction].freeze
    FOLLOWUP_ACTIONS = %w[contact_connector direct_outreach follow_up reconnect].freeze
    TRAVEL_ACTIONS = %w[travel].freeze

    def simulate(plan)
      metadata = plan.metadata
      SimulationResult.new(
        meetings: metadata.fetch("expected_meetings", count(plan, MEETING_ACTIONS)),
        introductions: metadata.fetch("expected_introductions", count(plan, INTRODUCTION_ACTIONS)),
        followups: metadata.fetch("expected_followups", count(plan, FOLLOWUP_ACTIONS)),
        duration_days: metadata.fetch("expected_duration_days", critical_path_duration(plan)),
        budget: metadata.fetch("budget", 0),
        travel_required: metadata.fetch("travel_required", count(plan, TRAVEL_ACTIONS).positive?),
        cold_outreach: metadata.fetch("cold_outreach", false),
        confidence: simulation_confidence(plan)
      )
    end

    private

    def count(plan, actions)
      plan.steps.count { |step| actions.include?(step.action) }
    end

    def critical_path_duration(plan)
      by_id = plan.steps.to_h { |step| [step.step_id, step] }
      cache = {}
      calculate = lambda do |step|
        cache[step.step_id] ||= step.estimated_duration_days + step.depends_on.map do |dependency|
          calculate.call(by_id.fetch(dependency))
        end.max.to_i
      end
      plan.steps.map { |step| calculate.call(step) }.max.to_i
    end

    def simulation_confidence(plan)
      evidence_coverage = [plan.evidence.length.to_f / [plan.steps.length, 1].max, 1.0].min
      (0.75 * plan.confidence + 0.25 * evidence_coverage).round(6)
    end
  end
end
