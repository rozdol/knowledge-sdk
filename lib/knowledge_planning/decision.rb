# frozen_string_literal: true

require "yaml"

module KnowledgePlanning
  class DecisionPolicy
    DEFAULT_PATH = File.expand_path("../../config/planning_policies.yml", __dir__).freeze

    attr_reader :version, :weights, :rules, :objectives

    def self.load(path = DEFAULT_PATH)
      payload = YAML.safe_load(File.read(path), aliases: false)
      new(payload)
    rescue Psych::SyntaxError => error
      raise Error, "invalid planning policy configuration: #{error.message}"
    rescue Errno::ENOENT, Errno::EACCES => error
      raise Error, "planning policy cannot be read: #{error.message}"
    end

    def initialize(data)
      raise Error, "planning policy must be an object" unless data.is_a?(Hash)

      values = data.transform_keys(&:to_s)
      @version = values.fetch("version").to_s.freeze
      raw_weights = values.fetch("weights")
      raise Error, "planning policy weights must be an object" unless raw_weights.is_a?(Hash)

      @weights = raw_weights.each_with_object({}) do |(key, value), result|
        number = Float(value)
        raise Error, "planning policy weights must be non-negative" if number.negative?
        result[key.to_s] = number
      end.sort.to_h.freeze
      raise Error, "planning policy must have a positive total weight" unless @weights.values.sum.positive?

      @rules = Array(values.fetch("rules")).map do |item|
        normalized = item.transform_keys(&:to_s)
        {
          "id" => normalized.fetch("id").to_s,
          "criterion" => normalized.fetch("criterion").to_s,
          "message" => normalized.fetch("message").to_s
        }.freeze
      end.sort_by { |item| item.fetch("id") }.freeze
      @objectives = Array(values.fetch("objectives")).map do |item|
        normalized = item.transform_keys(&:to_s)
        direction = normalized.fetch("direction").to_s
        raise Error, "objective direction must be maximize or minimize" unless %w[maximize minimize].include?(direction)
        { "name" => normalized.fetch("name").to_s, "direction" => direction }.freeze
      end.freeze
      validate_rules!
      freeze
    rescue KeyError, ArgumentError, TypeError => error
      raise Error, "invalid planning policy: #{error.message}"
    end

    private

    def validate_rules!
      missing = weights.keys - rules.map { |rule| rule.fetch("criterion") }
      raise Error, "planning policy lacks rule explanations for: #{missing.join(', ')}" unless missing.empty?
    end
  end

  class DecisionEngine
    attr_reader :policy

    def initialize(policy: DecisionPolicy.load)
      @policy = policy
    end

    def decide(goal:, scenarios:, snapshot_digest:, as_of:, generator_trace: {})
      ordered = Array(scenarios).sort_by { |scenario| scenario.plan.plan_id }
      scores = ordered.to_h { |scenario| [scenario.plan.plan_id, score(scenario)] }
      feasible = ordered.select(&:feasible?)
      pareto_ids = pareto_frontier(feasible).map { |scenario| scenario.plan.plan_id }
      ranked_scenarios = feasible.sort_by do |scenario|
        [-scores.fetch(scenario.plan.plan_id).fetch("utility_score"), scenario.plan.plan_id]
      end
      rejected = (ordered - feasible).sort_by { |scenario| [scenario.violations.length, scenario.plan.plan_id] }
      all = ranked_scenarios + rejected
      ranked = all.each_with_index.map do |scenario, index|
        approved = index.zero? && scenario.feasible?
        status = if approved
                   "decision_approved"
                 elsif scenario.feasible?
                   "alternative"
                 else
                   "constraint_rejected"
                 end
        RankedPlan.new(
          rank: index + 1, scenario: scenario, decision_status: status,
          utility_score: scores.fetch(scenario.plan.plan_id).fetch("utility_score"),
          pareto_optimal: pareto_ids.include?(scenario.plan.plan_id),
          score_trace: scores.fetch(scenario.plan.plan_id).fetch("components"),
          explanation: explanation(status, scenario, scores.fetch(scenario.plan.plan_id))
        )
      end
      trace = build_trace(goal, ordered, ranked, generator_trace, pareto_ids)
      DecisionResult.new(
        goal: goal, snapshot_digest: snapshot_digest, as_of: as_of,
        policy_version: policy.version, ranked_plans: ranked, trace: trace
      )
    end

    private

    def score(scenario)
      components = policy.weights.keys.sort.map do |criterion|
        raw = scenario.criteria.fetch(criterion, 0.0).to_f
        weight = policy.weights.fetch(criterion)
        rule = policy.rules.find { |item| item.fetch("criterion") == criterion }
        {
          "criterion" => criterion, "raw_value" => raw.round(6), "weight" => weight,
          "contribution" => (raw * weight).round(6), "rule_id" => rule.fetch("id"),
          "rule" => rule.fetch("message")
        }.freeze
      end
      utility = components.sum { |item| item.fetch("contribution") } / policy.weights.values.sum
      { "utility_score" => utility.round(6), "components" => components.freeze }.freeze
    end

    def pareto_frontier(scenarios)
      scenarios.reject do |candidate|
        scenarios.any? { |other| other != candidate && dominates?(other, candidate) }
      end.sort_by { |scenario| scenario.plan.plan_id }
    end

    def dominates?(first, second)
      comparisons = policy.objectives.map do |objective|
        first_value = objective_value(first, objective.fetch("name"))
        second_value = objective_value(second, objective.fetch("name"))
        if objective.fetch("direction") == "minimize"
          [first_value <= second_value, first_value < second_value]
        else
          [first_value >= second_value, first_value > second_value]
        end
      end
      comparisons.all?(&:first) && comparisons.any?(&:last)
    end

    def objective_value(scenario, name)
      return scenario.criteria.fetch(name, 0.0).to_f if scenario.criteria.key?(name)

      case name
      when "meetings" then scenario.simulation.meetings.to_f
      when "introductions" then scenario.simulation.introductions.to_f
      when "effort" then scenario.plan.estimated_effort
      when "risk" then scenario.plan.risk_score
      when "duration_days" then scenario.simulation.duration_days.to_f
      else 0.0
      end
    end

    def explanation(status, scenario, score_data)
      if status == "constraint_rejected"
        names = scenario.violations.map { |item| item.fetch("constraint") }.join(", ")
        return "Rejected by hard constraints: #{names}."
      end
      strongest = score_data.fetch("components").sort_by do |item|
        [-item.fetch("contribution"), item.fetch("criterion")]
      end.first(3).map { |item| "#{item.fetch('criterion')}=#{item.fetch('raw_value')}" }.join(", ")
      prefix = status == "decision_approved" ? "Selected" : "Retained as an alternative"
      "#{prefix} by policy #{policy.version}; utility #{score_data.fetch('utility_score')}; strongest components: #{strongest}."
    end

    def build_trace(goal, scenarios, ranked, generator_trace, pareto_ids)
      chosen = ranked.find { |item| item.decision_status == "decision_approved" }
      {
        "goal" => goal.planning_signature,
        "constraints" => goal.constraints.to_h,
        "candidate_generation" => Immutable.copy(generator_trace).merge(
          "candidate_plan_ids" => scenarios.map { |scenario| scenario.plan.plan_id }
        ),
        "scenario_evaluation" => scenarios.map do |scenario|
          {
            "scenario_id" => scenario.scenario_id, "plan_id" => scenario.plan.plan_id,
            "criteria" => scenario.criteria, "simulation" => scenario.simulation.to_h,
            "constraints_satisfied" => scenario.feasible?, "violations" => scenario.violations
          }
        end,
        "decision" => {
          "policy_version" => policy.version, "policy_weights" => policy.weights,
          "pareto_plan_ids" => pareto_ids, "chosen_plan_id" => chosen && chosen.plan.plan_id,
          "ranking" => ranked.map do |item|
            {
              "rank" => item.rank, "plan_id" => item.plan.plan_id,
              "status" => item.decision_status, "utility_score" => item.utility_score,
              "why" => item.explanation
            }
          end
        },
        "approved_plan_is_executable" => false,
        "execution_boundary" => "Proposal -> explicit human approval -> existing Engine"
      }
    end
  end
end
