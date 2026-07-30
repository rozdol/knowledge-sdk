# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"

module KnowledgePlanning
  class CLI
    def initialize(group:, argv:, out:, err:, stdin:, vault_root:, event_bus: nil)
      @group = group.to_s
      @argv = argv.dup
      @out = out
      @err = err
      @stdin = stdin
      @vault_root = vault_root.to_s
      @event_bus = event_bus
      @options = { as_of: Date.today, persist: false }
    end

    def run
      case @group
      when "goal" then goal_command
      when "plan" then plan_command
      else raise Error, "unknown planning command group #{@group.inspect}"
      end
      0
    rescue OptionParser::ParseError, JSON::ParserError, KeyError, Error => error
      @err.puts(JSON.generate(error: error.message, error_class: error.class.name))
      2
    end

    private

    def goal_command
      command = @argv.shift
      case command
      when "create"
        payload = parse_json_source(@argv.shift)
        goal = goal_store.create(payload)
        publish_goal_event("GoalCreated", goal)
        emit(goal.to_h)
      when "list"
        status = nil
        OptionParser.new { |options| options.on("--status STATUS") { |value| status = value } }.parse!(@argv)
        emit(goals: goal_store.list(status: status).map(&:to_h))
      when "archive"
        goal = goal_store.archive(@argv.shift || raise(InvalidGoal, "goal ID is required"))
        publish_goal_event("GoalArchived", goal)
        emit(goal.to_h)
      when "help", "--help", "-h", nil
        @out.puts("Usage: kg goal create JSON|-|FILE | kg goal list [--status STATUS] | kg goal archive GOAL_ID")
      else raise InvalidGoal, "unknown goal command #{command.inspect}"
      end
    end

    def plan_command
      command = @argv.shift
      return plan_help if %w[help --help -h].include?(command) || command.nil?

      parse_plan_options!
      goal = resolve_goal(@argv.shift)
      result = planning_engine.plan(goal)
      case command
      when "goal" then emit(result.to_h)
      when "scenarios" then emit(scenarios: result.ranked_plans.map { |item| item.scenario.to_h })
      when "compare" then emit(compare_payload(result))
      when "simulate" then emit_simulation(result, @argv.shift)
      when "trace" then emit(result.trace)
      when "explain" then emit_explanation(result, @argv.shift)
      when "proposal"
        payload = ProposalAdapter.new.build(result)
        path = ProposalAdapter.new.persist(payload, vault_root: @vault_root) if @options[:persist]
        emit(proposal: payload, persisted: !!path)
      else raise InvalidGoal, "unknown plan command #{command.inspect}"
      end
    end

    def parse_plan_options!
      OptionParser.new do |options|
        options.on("--as-of DATE") { |value| @options[:as_of] = Date.iso8601(value) }
        options.on("--policy PATH") { |value| @options[:policy] = value }
        options.on("--persist") { @options[:persist] = true }
      end.parse!(@argv)
    end

    def resolve_goal(source)
      raise InvalidGoal, "goal ID or JSON is required" if source.to_s.empty?
      return goal_store.fetch(source) if source.to_s.match?(/\Agoal_[0-9A-HJKMNP-TV-Z]{26}\z/)

      values = parse_json_source(source).transform_keys(&:to_s)
      Goal.new(
        id: values["id"] || Stable.id("goal", values),
        description: values.fetch("description"), goal_type: values.fetch("goal_type", "generic"),
        priority: values.fetch("priority", "normal"), deadline: values["deadline"],
        constraints: values.fetch("constraints", {}), preferences: values.fetch("preferences", {}),
        success_criteria: values.fetch("success_criteria", []), status: values.fetch("status", "active"),
        created_at: values["created_at"]
      )
    end

    def parse_json_source(source)
      value = source
      value = @stdin.read if value.nil? || value == "-"
      candidate = Pathname.new(value.to_s)
      value = candidate.read if !value.to_s.lstrip.start_with?("{") && candidate.file?
      payload = JSON.parse(value.to_s)
      raise InvalidGoal, "goal payload must be an object" unless payload.is_a?(Hash)

      payload
    end

    def planning_engine
      snapshot = KnowledgeIntelligence::GraphSnapshot.load(vault_root: @vault_root)
      policy = @options[:policy] ? DecisionPolicy.load(@options[:policy]) : DecisionPolicy.load
      Engine.new(snapshot: snapshot, as_of: @options[:as_of], policy: policy)
    end

    def goal_store
      @goal_store ||= GoalStore.new(vault_root: @vault_root)
    end

    def publish_goal_event(type, goal)
      return unless @event_bus

      @event_bus.publish(
        type: type, source: "planning-goal-store",
        payload: { "goal" => goal.to_h, "goal_id" => goal.id, "as_of" => @options[:as_of].iso8601 }
      )
    end

    def compare_payload(result)
      {
        decision_id: result.decision_id,
        approved_plan_id: result.approved_plan && result.approved_plan.plan.plan_id,
        alternatives: result.ranked_plans.map do |item|
          {
            rank: item.rank, plan_id: item.plan.plan_id, title: item.plan.title,
            planner_id: item.plan.planner_id, status: item.decision_status,
            utility_score: item.utility_score, pareto_optimal: item.pareto_optimal,
            constraints_satisfied: item.scenario.feasible?, why: item.explanation
          }
        end
      }
    end

    def emit_simulation(result, plan_id)
      selected = select_ranked(result, plan_id)
      emit(plan_id: selected.plan.plan_id, simulation: selected.scenario.simulation.to_h,
           constraints_satisfied: selected.scenario.feasible?, violations: selected.scenario.violations)
    end

    def emit_explanation(result, plan_id)
      selected = select_ranked(result, plan_id)
      winner = result.approved_plan
      emit(
        decision_id: result.decision_id, plan_id: selected.plan.plan_id,
        selected: selected.decision_status == "decision_approved", why: selected.explanation,
        why_not: selected == winner ? result.ranked_plans.drop(1).map(&:explanation) :
          ["Plan #{winner && winner.plan.plan_id} ranked higher under policy #{result.policy_version}."],
        score_trace: selected.score_trace, graph_evidence: selected.plan.evidence.map(&:to_h),
        constraint_violations: selected.scenario.violations
      )
    end

    def select_ranked(result, plan_id)
      return result.approved_plan || result.ranked_plans.first if plan_id.to_s.empty?

      result.ranked_plans.find { |item| item.plan.plan_id == plan_id } ||
        raise(InvalidPlan, "plan not found in deterministic result: #{plan_id}")
    end

    def emit(value)
      @out.puts(JSON.pretty_generate(Immutable.canonical(value)))
    end

    def plan_help
      @out.puts("Usage: kg plan goal|scenarios|compare|simulate|trace|explain|proposal GOAL_ID|JSON [PLAN_ID] [options]")
      @out.puts("Options: --as-of DATE, --policy PATH, --persist (proposal only)")
    end
  end
end
