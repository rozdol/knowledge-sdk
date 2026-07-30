# frozen_string_literal: true

module KnowledgePlanning
  class PlanningContext
    attr_reader :snapshot, :feature_engine, :search, :as_of

    def initialize(snapshot:, feature_engine:, as_of:)
      @snapshot = snapshot
      @feature_engine = feature_engine
      @as_of = as_of.is_a?(Date) ? as_of : Date.iso8601(as_of.to_s)
      @search = GraphSearch.new(snapshot: snapshot, as_of: @as_of)
      freeze
    end
  end

  class Planner
    attr_reader :planner_id, :version, :goal_types

    def initialize(planner_id:, version: "1.0.0", goal_types:)
      @planner_id = planner_id.to_s.freeze
      @version = version.to_s.freeze
      @goal_types = Array(goal_types).map(&:to_s).freeze
      freeze
    end

    def supports?(goal)
      goal_types.include?(goal.goal_type) || goal_types.include?("*")
    end

    def plan(_goal, _graph, _constraints, context:)
      raise NotImplementedError, "planner must implement plan(goal, graph, constraints)"
    end

    protected

    def targets(goal, graph, types:, filter: nil)
      requested = Array(goal.preferences["target_ids"]).map(&:to_s)
      records = if requested.empty?
                  Array(types).flat_map { |type| graph.records(type: type) }
                else
                  requested.map { |id| graph.record(id) }.compact
                end
      records = records.select { |record| Array(types).include?(record.type) }
      records = records.select(&filter) if filter
      limit = [[goal.preferences.fetch("candidate_limit", 5).to_i, 1].max, 25].min
      records.sort_by { |record| [record.name.to_s, record.id] }.first(limit)
    end

    def record_label(record)
      record&.name.to_s.empty? ? record&.id.to_s : record.name.to_s
    end

    def link(record)
      label = record_label(record)
      "[[#{record.path.sub(/\.md\z/, "")}|#{label}]]"
    end

    def followup_intent(context, target, action, goal)
      owner = context.snapshot.record(context.snapshot.self_id)
      return nil unless owner

      attributes = {
        "name" => "#{action}: #{record_label(target)}",
        "owner" => link(owner), "action" => action,
        "followup_status" => "open", "due_on" => (context.as_of + 7).iso8601,
        "priority" => goal.priority == "critical" ? "high" : goal.priority,
        "sensitivity" => "private", "data_origin" => "inferred"
      }
      attributes["with"] = [link(target)] if target && target.type == "person"
      {
        "type" => "CreateEntity",
        "params" => { "entity_type" => "follow-up", "attributes" => attributes }
      }
    end

    def build_step(goal, index, action:, description:, entity_ids: [], depends_on: [],
                   duration: 1, intent: nil, approval: nil)
      PlanStep.new(
        seed: [goal.id, planner_id, index], action: action, description: description,
        entity_ids: entity_ids, depends_on: depends_on,
        estimated_duration_days: duration,
        required_approval: approval || (intent ? "human_review" : "none"), intent: intent
      )
    end

    def plan_metadata(goal, entity_ids:, target_ids:, path: [], existing_contacts: false,
                      cold_outreach: false, extra: {})
      {
        "entity_ids" => Array(entity_ids).map(&:to_s).uniq.sort,
        "target_ids" => Array(target_ids).map(&:to_s).uniq.sort,
        "graph_path" => Array(path).map(&:to_s),
        "existing_contacts" => !!existing_contacts,
        "cold_outreach" => !!cold_outreach,
        "preference_alignment" => preference_alignment(goal, target_ids),
        "benefits" => Array(extra.delete(:benefits) || extra.delete("benefits"))
      }.merge(extra.transform_keys(&:to_s))
    end

    def preference_alignment(goal, target_ids)
      requested = Array(goal.preferences["target_ids"]).map(&:to_s)
      return 0.75 if requested.empty?

      covered = Array(target_ids).map(&:to_s) & requested
      (covered.length.to_f / requested.length).round(6)
    end
  end

  class WarmIntroductionPlanner < Planner
    GOALS = %w[warm_introduction network_expansion customer_acquisition fundraising recruiting].freeze

    def initialize
      super(planner_id: "warm_introduction", goal_types: GOALS)
    end

    def plan(goal, graph, _constraints, context:)
      available_targets(goal, graph).flat_map do |target|
        context.search.alternative_paths(
          graph.self_id, target.id, mode: "knowledge",
          limit: goal.preferences.fetch("path_limit", 3),
          max_depth: goal.preferences.fetch("max_path_depth", 5)
        ).map.with_index do |path, path_index|
          build_plan(goal, target, path, path_index, context)
        end
      end.compact
    end

    private

    def available_targets(goal, graph)
      explicit = !Array(goal.preferences["target_ids"]).empty?
      types = case goal.goal_type
              when "fundraising" then %w[organization person]
              when "customer_acquisition" then %w[organization person]
              else %w[person organization]
              end
      filter = lambda do |record|
        next false if record.id == graph.self_id
        next true if explicit
        next record["org_kind"] == "fund" if goal.goal_type == "fundraising" && record.type == "organization"
        next record["org_kind"] == "company" if goal.goal_type == "customer_acquisition" && record.type == "organization"

        true
      end
      targets(goal, graph, types: types, filter: filter)
    end

    def build_plan(goal, target, path, path_index, context)
      return nil if path.length < 2

      contact = context.snapshot.record(path[1])
      return nil unless contact && contact.type == "person"
      return nil unless path[0...-1].all? { |id| context.snapshot.record(id)&.type == "person" }

      action = "Contact #{record_label(contact)} about #{record_label(target)}"
      first = build_step(
        goal, [target.id, path_index, 1], action: "contact_connector",
        description: action, entity_ids: [contact.id], duration: 1,
        intent: followup_intent(context, contact, action, goal)
      )
      steps = [first]
      if path.length > 2
        introduction = build_step(
          goal, [target.id, path_index, 2], action: "request_introduction",
          description: "Ask #{record_label(contact)} for the trusted path to #{record_label(target)}.",
          entity_ids: path, depends_on: [first.step_id], duration: 3, approval: "human_review"
        )
        steps << introduction
      end
      final = build_step(
        goal, [target.id, path_index, 3], action: "meeting",
        description: "Hold a goal-focused meeting with #{record_label(target)}.",
        entity_ids: [target.id], depends_on: [steps.last.step_id], duration: 3,
        approval: "human_review"
      )
      steps << final
      evidence = context.search.edge_evidence(path, mode: "knowledge")
      existing = contact.type == "person" && context.search.direct_contact?(context.snapshot.self_id, contact.id)
      CandidatePlan.new(
        goal_id: goal.id, planner_id: planner_id, planner_version: version,
        title: "Trusted path via #{record_label(contact)} to #{record_label(target)}",
        steps: steps, estimated_effort: steps.length * 2.0,
        estimated_value: [0.9 - (path.length - 2) * 0.08, 0.5].max,
        confidence: evidence.empty? ? 0.45 : [0.65 + evidence.length * 0.05, 0.95].min,
        evidence: evidence, risk: existing ? "low" : "medium",
        metadata: plan_metadata(
          goal, entity_ids: path, target_ids: [target.id], path: path,
          existing_contacts: existing, cold_outreach: false,
          extra: {
            expected_introductions: path.length > 2 ? 1 : 0, expected_meetings: 1,
            expected_followups: 2, benefits: ["Uses graph-supported trusted path", "Avoids cold outreach"]
          }
        )
      )
    end
  end

  class DirectOutreachPlanner < Planner
    GOALS = %w[network_expansion customer_acquisition fundraising recruiting customer_recovery].freeze

    def initialize
      super(planner_id: "direct_outreach", goal_types: GOALS)
    end

    def plan(goal, graph, _constraints, context:)
      target_types = %w[person organization]
      targets(goal, graph, types: target_types, filter: ->(record) { record.id != graph.self_id }).map do |target|
        social = target.type == "person" && context.search.direct_contact?(graph.self_id, target.id)
        knowledge_path = context.search.shortest_path(graph.self_id, target.id, mode: "knowledge")
        existing = social || (knowledge_path && knowledge_path.length == 2)
        action = "Prepare direct outreach to #{record_label(target)}"
        first = build_step(
          goal, [target.id, 1], action: "direct_outreach", description: action,
          entity_ids: [target.id], duration: 1,
          intent: followup_intent(context, target, action, goal)
        )
        second = build_step(
          goal, [target.id, 2], action: "follow_up",
          description: "Review response and follow up once if appropriate.",
          entity_ids: [target.id], depends_on: [first.step_id], duration: 5,
          approval: "human_review"
        )
        evidence = knowledge_path ? context.search.edge_evidence(knowledge_path, mode: "knowledge") : []
        CandidatePlan.new(
          goal_id: goal.id, planner_id: planner_id, planner_version: version,
          title: "Direct outreach to #{record_label(target)}", steps: [first, second],
          estimated_effort: 3.0, estimated_value: existing ? 0.68 : 0.5,
          confidence: evidence.empty? ? 0.35 : 0.65, evidence: evidence,
          risk: existing ? "medium" : "high",
          metadata: plan_metadata(
            goal, entity_ids: [target.id], target_ids: [target.id], path: knowledge_path || [],
            existing_contacts: existing, cold_outreach: !existing,
            extra: { expected_followups: 2, benefits: ["Shortest operational route"] }
          )
        )
      end
    end
  end

  class RelationshipMaintenancePlanner < Planner
    def initialize
      super(planner_id: "relationship_maintenance", goal_types: %w[relationship_maintenance customer_recovery])
    end

    def plan(goal, graph, _constraints, context:)
      selected = targets(
        goal, graph, types: ["person"],
        filter: ->(record) { record.id != graph.self_id && (record["tier"] == "dormant" || !Array(goal.preferences["target_ids"]).empty?) }
      )
      selected.map do |person|
        existing = context.search.direct_contact?(graph.self_id, person.id)
        action = "Reconnect with #{record_label(person)}"
        first = build_step(
          goal, [person.id, 1], action: "reconnect", description: action,
          entity_ids: [person.id], duration: 1,
          intent: followup_intent(context, person, action, goal)
        )
        second = build_step(
          goal, [person.id, 2], action: "meeting",
          description: "Meet only if the reconnection is welcomed.", entity_ids: [person.id],
          depends_on: [first.step_id], duration: 7, approval: "human_review"
        )
        path = context.search.shortest_path(graph.self_id, person.id, mode: "social")
        CandidatePlan.new(
          goal_id: goal.id, planner_id: planner_id, planner_version: version,
          title: "Relationship recovery with #{record_label(person)}", steps: [first, second],
          estimated_effort: 3.0, estimated_value: 0.75, confidence: existing ? 0.75 : 0.45,
          evidence: path ? context.search.edge_evidence(path, mode: "social") : [],
          risk: existing ? "low" : "medium",
          metadata: plan_metadata(
            goal, entity_ids: [person.id], target_ids: [person.id], path: path || [],
            existing_contacts: existing, cold_outreach: !existing,
            extra: { expected_meetings: 1, expected_followups: 1,
                     benefits: ["Restores an existing relationship before expansion"] }
          )
        )
      end
    end
  end

  class EventPlanner < Planner
    def initialize
      super(planner_id: "event_strategy", goal_types: %w[conference network_expansion customer_acquisition fundraising recruiting travel])
    end

    def plan(goal, graph, _constraints, context:)
      events = targets(goal, graph, types: ["event"], filter: lambda do |record|
        starts = graph.parse_time(record["starts_at"])
        !starts || starts.to_date >= context.as_of
      end)
      events.map do |event|
        scheduled = graph.parse_time(event["starts_at"])
        location = event["location"] || event["city"] || goal.preferences["location"]
        first = build_step(
          goal, [event.id, 1], action: "prepare_event",
          description: "Select relevant participants and objectives for #{record_label(event)}.",
          entity_ids: [event.id], duration: 3
        )
        second = build_step(
          goal, [event.id, 2], action: "attend_event",
          description: "Attend #{record_label(event)} with bounded meeting targets.",
          entity_ids: [event.id], depends_on: [first.step_id], duration: 1,
          approval: "human_review"
        )
        third = build_step(
          goal, [event.id, 3], action: "follow_up",
          description: "Review and approve post-event follow-ups.",
          entity_ids: [event.id], depends_on: [second.step_id], duration: 3,
          approval: "human_review"
        )
        CandidatePlan.new(
          goal_id: goal.id, planner_id: planner_id, planner_version: version,
          title: "Event route through #{record_label(event)}", steps: [first, second, third],
          estimated_effort: 7.0, estimated_value: 0.72, confidence: 0.6,
          evidence: [graph.evidence(event, field: "starts_at")], risk: "medium",
          metadata: plan_metadata(
            goal, entity_ids: [event.id], target_ids: [event.id], existing_contacts: true,
            cold_outreach: false,
            extra: {
              location: location, scheduled_on: scheduled && scheduled.to_date.iso8601,
              travel_required: goal.preferences.fetch("travel_required", !location.to_s.empty?),
              budget: goal.preferences.fetch("event_budget", 0), expected_meetings: 3,
              expected_followups: 3, benefits: ["Concentrates several opportunities in one scenario"]
            }
          )
        )
      end
    end
  end

  class StaffingPlanner < Planner
    def initialize
      super(planner_id: "project_staffing", goal_types: %w[recruiting project_launch])
    end

    def plan(goal, graph, _constraints, context:)
      targets(goal, graph, types: ["person"], filter: ->(record) { record.id != graph.self_id }).map do |person|
        existing = context.search.direct_contact?(graph.self_id, person.id)
        first = build_step(
          goal, [person.id, 1], action: "shortlist",
          description: "Validate graph evidence for #{record_label(person)} against the role criteria.",
          entity_ids: [person.id], duration: 2
        )
        action = "Discuss the role with #{record_label(person)}"
        second = build_step(
          goal, [person.id, 2], action: "interview", description: action,
          entity_ids: [person.id], depends_on: [first.step_id], duration: 5,
          intent: followup_intent(context, person, action, goal)
        )
        path = context.search.shortest_path(graph.self_id, person.id, mode: "social")
        CandidatePlan.new(
          goal_id: goal.id, planner_id: planner_id, planner_version: version,
          title: "Staffing path for #{record_label(person)}", steps: [first, second],
          estimated_effort: 6.0, estimated_value: 0.7, confidence: path ? 0.7 : 0.4,
          evidence: path ? context.search.edge_evidence(path, mode: "social") : [],
          risk: existing ? "low" : "high",
          metadata: plan_metadata(
            goal, entity_ids: [person.id], target_ids: [person.id], path: path || [],
            existing_contacts: existing, cold_outreach: !existing,
            extra: { expected_meetings: 1, expected_followups: 1,
                     benefits: ["Separates evidence review from outreach"] }
          )
        )
      end
    end
  end

  class TravelPlanner < Planner
    def initialize
      super(planner_id: "travel_strategy", goal_types: ["travel"])
    end

    def plan(goal, graph, _constraints, context:)
      targets(goal, graph, types: %w[city place]).map do |destination|
        first = build_step(
          goal, [destination.id, 1], action: "build_itinerary",
          description: "Build a bounded itinerary for #{record_label(destination)}.",
          entity_ids: [destination.id], duration: 2
        )
        second = build_step(
          goal, [destination.id, 2], action: "travel",
          description: "Travel to #{record_label(destination)} only after itinerary approval.",
          entity_ids: [destination.id], depends_on: [first.step_id], duration: 1,
          approval: "human_review"
        )
        third = build_step(
          goal, [destination.id, 3], action: "meeting",
          description: "Use the configured meeting limit while in #{record_label(destination)}.",
          entity_ids: [destination.id], depends_on: [second.step_id], duration: 2,
          approval: "human_review"
        )
        CandidatePlan.new(
          goal_id: goal.id, planner_id: planner_id, planner_version: version,
          title: "Travel scenario: #{record_label(destination)}", steps: [first, second, third],
          estimated_effort: 8.0, estimated_value: 0.7, confidence: 0.65,
          evidence: [graph.evidence(destination, field: "name")], risk: "medium",
          metadata: plan_metadata(
            goal, entity_ids: [destination.id], target_ids: [destination.id],
            existing_contacts: true, cold_outreach: false,
            extra: {
              location: record_label(destination), travel_required: true,
              budget: goal.preferences.fetch("travel_budget", 0), expected_meetings: 2,
              benefits: ["Makes travel cost and meeting limits explicit"]
            }
          )
        )
      end
    end
  end

  class GenericPlanner < Planner
    def initialize
      super(planner_id: "generic_strategy", goal_types: ["*"])
    end

    def plan(goal, graph, _constraints, context:)
      return [] unless goal.goal_type == "generic" || Array(goal.preferences["target_ids"]).empty?

      first = build_step(
        goal, 1, action: "review_evidence",
        description: "Review graph evidence and define the smallest measurable next step.", duration: 1
      )
      second = build_step(
        goal, 2, action: "follow_up",
        description: "Create review-only follow-up proposals for the chosen next step.",
        depends_on: [first.step_id], duration: 2, approval: "human_review"
      )
      [CandidatePlan.new(
        goal_id: goal.id, planner_id: planner_id, planner_version: version,
        title: "Evidence-first baseline", steps: [first, second], estimated_effort: 2.0,
        estimated_value: 0.4, confidence: graph.records.empty? ? 0.25 : 0.5,
        evidence: [], risk: "low",
        metadata: plan_metadata(
          goal, entity_ids: [], target_ids: [], existing_contacts: true,
          extra: { expected_followups: 1, benefits: ["Provides a bounded baseline"] }
        )
      )]
    end
  end

  module DefaultPlanners
    module_function

    def build
      [
        WarmIntroductionPlanner.new, DirectOutreachPlanner.new,
        RelationshipMaintenancePlanner.new, EventPlanner.new,
        StaffingPlanner.new, TravelPlanner.new, GenericPlanner.new
      ].freeze
    end
  end

  class CandidatePlanGenerator
    attr_reader :planners

    def initialize(planners: DefaultPlanners.build)
      @planners = Array(planners).sort_by(&:planner_id).freeze
    end

    def generate(goal, context)
      candidates = planners.select { |planner| planner.supports?(goal) }.flat_map do |planner|
        planner.plan(goal, context.snapshot, goal.constraints, context: context)
      end
      candidates = candidates.uniq(&:plan_id).sort_by { |plan| [plan.planner_id, plan.plan_id] }
      limit = [[goal.preferences.fetch("maximum_candidates", 50).to_i, 1].max, 100].min
      candidates = candidates.first(limit)
      raise NoCandidates, "candidate planners produced no plans for goal #{goal.id}" if candidates.empty?

      ids = candidates.map(&:plan_id)
      candidates.map { |plan| plan.with_alternatives(ids) }.freeze
    end
  end
end
