# frozen_string_literal: true

require "date"
require "digest"
require "json"

module KnowledgePlanning
  module Immutable
    module_function

    def copy(value)
      KnowledgeIntelligence::Immutable.copy(value)
    end

    def canonical(value)
      KnowledgeIntelligence::Immutable.canonical(value)
    end
  end

  module Stable
    module_function

    def id(prefix, *parts)
      KnowledgeIntelligence::Stable.id(prefix, *parts)
    end

    def json(value)
      KnowledgeIntelligence::Stable.json(value)
    end
  end

  class Goal
    PRIORITIES = %w[low normal high critical].freeze
    STATUSES = %w[active archived completed].freeze

    attr_reader :id, :description, :goal_type, :priority, :deadline, :constraints,
                :preferences, :success_criteria, :status, :created_at

    def initialize(id:, description:, goal_type: "generic", priority: "normal", deadline: nil,
                   constraints: {}, preferences: {}, success_criteria: [], status: "active",
                   created_at: nil)
      @id = required(id, "goal id", 200)
      @description = required(description, "goal description", 2_000)
      @goal_type = required(goal_type, "goal type", 100)
      @priority = priority.to_s.freeze
      raise InvalidGoal, "invalid goal priority #{@priority.inspect}" unless PRIORITIES.include?(@priority)
      @deadline = parse_date(deadline)
      @constraints = constraints.is_a?(ConstraintSet) ? constraints : ConstraintSet.new(constraints)
      @preferences = Immutable.copy(preferences || {})
      raise InvalidGoal, "goal preferences must be an object" unless @preferences.is_a?(Hash)
      @success_criteria = Array(success_criteria).map { |item| required(item, "success criterion", 1_000) }.freeze
      @status = status.to_s.freeze
      raise InvalidGoal, "invalid goal status #{@status.inspect}" unless STATUSES.include?(@status)
      @created_at = created_at && created_at.to_s.freeze
      freeze
    end

    def active?
      status == "active"
    end

    def planning_signature
      {
        id: id, description: description, goal_type: goal_type, priority: priority,
        deadline: deadline && deadline.iso8601, constraints: constraints.to_h,
        preferences: preferences, success_criteria: success_criteria, status: status
      }
    end

    def with_status(value)
      self.class.new(**to_h.transform_keys(&:to_sym).merge(status: value))
    end

    def to_h
      planning_signature.merge(created_at: created_at).reject { |_key, value| value.nil? }
    end

    private

    def required(value, label, maximum)
      string = value.to_s.strip
      raise InvalidGoal, "#{label} is required" if string.empty?
      raise InvalidGoal, "#{label} is too long" if string.length > maximum

      string.freeze
    end

    def parse_date(value)
      return nil if value.nil? || value.to_s.empty?
      return value.freeze if value.is_a?(Date)

      Date.iso8601(value.to_s).freeze
    rescue ArgumentError
      raise InvalidGoal, "deadline must be an ISO 8601 date"
    end
  end

  class PlanStep
    attr_reader :step_id, :action, :description, :entity_ids, :depends_on,
                :estimated_duration_days, :required_approval, :intent

    def initialize(seed:, action:, description:, entity_ids: [], depends_on: [],
                   estimated_duration_days: 0, required_approval: "none", intent: nil)
      @action = action.to_s.freeze
      @description = description.to_s.freeze
      raise InvalidPlan, "plan step action and description are required" if @action.empty? || @description.empty?
      @entity_ids = Array(entity_ids).map(&:to_s).uniq.sort.freeze
      @depends_on = Array(depends_on).map(&:to_s).uniq.sort.freeze
      @estimated_duration_days = [estimated_duration_days.to_i, 0].max
      @required_approval = required_approval.to_s.freeze
      @intent = intent && Immutable.copy(intent)
      KnowledgeGraph::IntentFactory.build(Immutable.canonical(@intent)) if @intent
      @step_id = Stable.id("plan-step", seed, @action, @description, @entity_ids).freeze
      freeze
    rescue KnowledgeGraph::InvalidIntent => error
      raise InvalidPlan, "invalid generated Intent: #{error.message}"
    end

    def to_h
      {
        step_id: step_id, action: action, description: description, entity_ids: entity_ids,
        depends_on: depends_on, estimated_duration_days: estimated_duration_days,
        required_approval: required_approval, intent: intent, executable: false
      }.reject { |_key, value| value.nil? }
    end
  end

  class CandidatePlan
    RISKS = { "low" => 0.2, "medium" => 0.5, "high" => 0.8 }.freeze

    attr_reader :plan_id, :goal_id, :planner_id, :planner_version, :title, :steps,
                :alternatives, :estimated_effort, :estimated_value, :confidence,
                :risk, :evidence, :required_approvals, :metadata

    def initialize(goal_id:, planner_id:, planner_version:, title:, steps:,
                   estimated_effort:, estimated_value:, confidence:, evidence: [],
                   required_approvals: [], risk: "medium", metadata: {}, alternatives: [],
                   plan_id: nil)
      @goal_id = goal_id.to_s.freeze
      @planner_id = planner_id.to_s.freeze
      @planner_version = planner_version.to_s.freeze
      @title = title.to_s.freeze
      @steps = Array(steps).freeze
      raise InvalidPlan, "candidate plan requires a title and steps" if @title.empty? || @steps.empty?
      unless @steps.all? { |step| step.is_a?(PlanStep) }
        raise InvalidPlan, "candidate plan steps must be PlanStep objects"
      end
      validate_dependencies!
      @estimated_effort = [estimated_effort.to_f, 0.0].max.round(6)
      @estimated_value = clamp(estimated_value)
      @confidence = clamp(confidence)
      @risk = risk.to_s.freeze
      raise InvalidPlan, "invalid candidate risk #{@risk.inspect}" unless RISKS.key?(@risk)
      @evidence = Array(evidence).uniq { |item| item.evidence_id }.sort_by(&:evidence_id).freeze
      @required_approvals = (Array(required_approvals).map(&:to_s) + @steps.map(&:required_approval))
                            .reject { |value| value == "none" }.uniq.sort.freeze
      @metadata = Immutable.copy(metadata || {})
      @plan_id = (plan_id || Stable.id("plan", core_signature)).to_s.freeze
      @alternatives = Array(alternatives).map(&:to_s).reject { |id| id == @plan_id }.uniq.sort.freeze
      freeze
    end

    def generated_intents
      steps.map(&:intent).compact.freeze
    end

    def risk_score
      RISKS.fetch(risk)
    end

    def with_alternatives(ids)
      self.class.new(
        goal_id: goal_id, planner_id: planner_id, planner_version: planner_version,
        title: title, steps: steps, estimated_effort: estimated_effort,
        estimated_value: estimated_value, confidence: confidence, evidence: evidence,
        required_approvals: required_approvals, risk: risk, metadata: metadata,
        alternatives: ids, plan_id: plan_id
      )
    end

    def to_h
      {
        plan_id: plan_id, goal_id: goal_id, planner_id: planner_id,
        planner_version: planner_version, title: title, steps: steps.map(&:to_h),
        dependencies: steps.to_h { |step| [step.step_id, step.depends_on] },
        alternatives: alternatives, estimated_effort: estimated_effort,
        estimated_value: estimated_value, confidence: confidence, risk: risk,
        graph_evidence: evidence.map(&:to_h), required_approvals: required_approvals,
        generated_proposals: generated_intents, metadata: metadata, executable: false
      }
    end

    private

    def core_signature
      {
        goal_id: goal_id, planner_id: planner_id, planner_version: planner_version,
        title: title, steps: steps.map(&:to_h), estimated_effort: estimated_effort,
        estimated_value: estimated_value, confidence: confidence, risk: risk,
        evidence_ids: evidence.map(&:evidence_id), metadata: metadata
      }
    end

    def validate_dependencies!
      ids = @steps.map(&:step_id)
      @steps.each do |step|
        unknown = step.depends_on - ids
        raise InvalidPlan, "step has unknown dependencies: #{unknown.join(', ')}" unless unknown.empty?
      end
    end

    def clamp(value)
      [[value.to_f, 0.0].max, 1.0].min.round(6)
    end
  end

  class SimulationResult
    attr_reader :meetings, :introductions, :followups, :duration_days, :budget,
                :travel_required, :cold_outreach, :confidence

    def initialize(meetings:, introductions:, followups:, duration_days:, budget:,
                   travel_required:, cold_outreach:, confidence:)
      @meetings = meetings.to_i
      @introductions = introductions.to_i
      @followups = followups.to_i
      @duration_days = duration_days.to_i
      @budget = budget.to_f.round(2)
      @travel_required = !!travel_required
      @cold_outreach = !!cold_outreach
      @confidence = [[confidence.to_f, 0.0].max, 1.0].min.round(6)
      freeze
    end

    def to_h
      {
        meetings: meetings, introductions: introductions, followups: followups,
        duration_days: duration_days, budget: budget, travel_required: travel_required,
        cold_outreach: cold_outreach, confidence: confidence
      }
    end
  end

  class ScenarioEvaluation
    attr_reader :scenario_id, :plan, :simulation, :criteria, :feature_trace,
                :violations, :benefits, :risks, :cost, :expected_outcome, :confidence

    def initialize(plan:, simulation:, criteria:, feature_trace:, violations:,
                   benefits:, risks:, cost:, expected_outcome:, confidence:)
      @plan = plan
      @simulation = simulation
      @criteria = Immutable.copy(criteria)
      @feature_trace = Immutable.copy(feature_trace)
      @violations = Immutable.copy(violations)
      @benefits = Array(benefits).map(&:to_s).uniq.sort.freeze
      @risks = Array(risks).map(&:to_s).uniq.sort.freeze
      @cost = Immutable.copy(cost)
      @expected_outcome = expected_outcome.to_s.freeze
      @confidence = [[confidence.to_f, 0.0].max, 1.0].min.round(6)
      @scenario_id = Stable.id("scenario", plan.plan_id, simulation.to_h, @criteria, @violations).freeze
      freeze
    end

    def feasible?
      violations.empty?
    end

    def to_h
      {
        scenario_id: scenario_id, plan: plan.to_h, benefits: benefits, risks: risks,
        cost: cost, expected_outcome: expected_outcome, confidence: confidence,
        simulation: simulation.to_h, criteria: criteria, feature_trace: feature_trace,
        constraints_satisfied: feasible?, constraint_violations: violations
      }
    end
  end

  class RankedPlan
    attr_reader :rank, :scenario, :decision_status, :utility_score,
                :pareto_optimal, :score_trace, :explanation

    def initialize(rank:, scenario:, decision_status:, utility_score:, pareto_optimal:,
                   score_trace:, explanation:)
      @rank = rank.to_i
      @scenario = scenario
      @decision_status = decision_status.to_s.freeze
      @utility_score = utility_score.to_f.round(6)
      @pareto_optimal = !!pareto_optimal
      @score_trace = Immutable.copy(score_trace)
      @explanation = explanation.to_s.freeze
      freeze
    end

    def plan
      scenario.plan
    end

    def to_h
      {
        rank: rank, decision_status: decision_status, utility_score: utility_score,
        pareto_optimal: pareto_optimal, explanation: explanation,
        score_trace: score_trace, scenario: scenario.to_h
      }
    end
  end

  class DecisionResult
    attr_reader :decision_id, :goal, :snapshot_digest, :as_of, :policy_version,
                :ranked_plans, :approved_plan, :trace

    def initialize(goal:, snapshot_digest:, as_of:, policy_version:, ranked_plans:, trace:)
      @goal = goal
      @snapshot_digest = snapshot_digest.to_s.freeze
      @as_of = as_of.is_a?(Date) ? as_of.iso8601.freeze : as_of.to_s.freeze
      @policy_version = policy_version.to_s.freeze
      @ranked_plans = Array(ranked_plans).freeze
      @approved_plan = @ranked_plans.find { |item| item.decision_status == "decision_approved" }
      @trace = Immutable.copy(trace)
      @decision_id = Stable.id(
        "decision", goal.planning_signature, @snapshot_digest, @as_of, @policy_version,
        @ranked_plans.map { |item| [item.plan.plan_id, item.utility_score, item.decision_status] }
      ).freeze
      freeze
    end

    def to_h
      {
        decision_id: decision_id, goal: goal.to_h, snapshot_digest: snapshot_digest,
        as_of: as_of, policy_version: policy_version,
        approved_plan: approved_plan && approved_plan.to_h,
        ranked_plans: ranked_plans.map(&:to_h), decision_trace: trace,
        executable: false
      }
    end
  end
end
