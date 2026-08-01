# frozen_string_literal: true

require "date"
require "json"
require "time"

module KnowledgeActivity
  class Timeline
    DEFAULT_LIMIT = 20

    def initialize(vault_root:, clock: nil, event_store: nil, proposal_store: nil, event_bus: nil, cache: nil)
      @vault_root = File.expand_path(vault_root.to_s)
      @clock = clock || -> { Time.now }
      @audit_log = KnowledgeGraph::AuditLog.new(vault_root: @vault_root)
      @event_store = event_store || KnowledgeOrchestration::EventStore.new(vault_root: @vault_root)
      @proposal_store = proposal_store || KnowledgeExtraction::ProposalStore.new(vault_root: @vault_root)
      @event_bus = event_bus
      @cache = cache || KnowledgeOrchestration::KnowledgeCache.new(vault_root: @vault_root, clock: @clock)
    end

    def latest(actor: nil, source: nil)
      filtered(actor: actor, source: source).last
    end

    def recent(limit: DEFAULT_LIMIT, actor: nil, source: nil)
      limited(filtered(actor: actor, source: source).reverse, limit)
    end

    def today(limit: nil, actor: nil, source: nil)
      start = local_day_start(@clock.call)
      between(from_time: start, to_time: start + 86_400, limit: limit, actor: actor, source: source)
    end

    def yesterday(limit: nil, actor: nil, source: nil)
      finish = local_day_start(@clock.call)
      between(from_time: finish - 86_400, to_time: finish, limit: limit, actor: actor, source: source)
    end

    def since(time:, limit: nil, actor: nil, source: nil)
      select_time(from_time: parse_time(time), limit: limit, actor: actor, source: source)
    end

    def between(from_time:, to_time:, limit: nil, actor: nil, source: nil)
      from = parse_time(from_time)
      to = parse_time(to_time)
      raise InvalidActivityQuery, "--to must be after --from" unless to > from

      select_time(from_time: from, to_time: to, limit: limit, actor: actor, source: source)
    end

    def search(query:, limit: DEFAULT_LIMIT, actor: nil, source: nil)
      needle = query.to_s.strip.downcase
      raise InvalidActivityQuery, "search requires --query" if needle.empty?

      matches = filtered(actor: actor, source: source).select do |activity|
        searchable(activity).downcase.include?(needle)
      end.reverse
      limited(matches, limit)
    end

    def find(reference)
      value = reference.to_s
      activity = all.find { |item| item.id == value || item.audit.fetch("id") == value }
      activity || raise(ActivityNotFound, "activity not found: #{reference}")
    end

    def explain(reference)
      activity = reference.is_a?(Activity) ? reference : find(reference)
      proposal = load_proposal(activity.proposal)
      approval = activity.proposal && @proposal_store.approval(activity.proposal)
      {
        status: "ok", activity: activity.to_h,
        explanation: {
          origin: {
            source: activity.source, actor: activity.actor,
            activity_id: activity.id, originating_proposal: activity.proposal,
            event_references: activity.events
          }.reject { |_key, value| value.nil? },
          evidence: public_evidence(proposal, activity),
          proposal: public_proposal(proposal),
          approval: public_approval(approval),
          execution: {
            status: activity.audit.fetch("result"), reference: activity.audit.fetch("id"),
            time: activity.audit.fetch("timestamp"), actor: activity.actor,
            run: activity.audit["run_id"]
          }.reject { |_key, value| value.nil? },
          resulting_changes: {
            affected_objects: activity.affected_objects,
            changed_object_count: activity.audit.fetch("changed_paths", []).length,
            current_snapshot: current_snapshot_digest
          }
        }
      }
    end

    def create_proposal(reference, operation:)
      activity = reference.is_a?(Activity) ? reference : find(reference)
      proposal = proposal_adapter.create(activity, operation: operation)
      {
        status: "ok", proposal: proposal.fetch("proposal_id"),
        summary: proposal.fetch("summary"), approval_required: true,
        activity: activity.id, operation: operation.to_s
      }
    end

    def diff(from:, to:, limit: nil, actor: nil, source: nil)
      from_activity = find(from)
      to_activity = find(to)
      from_index = all.index(from_activity)
      to_index = all.index(to_activity)
      raise InvalidActivityQuery, "diff --to must not precede --from" if to_index < from_index

      changes = all[(from_index + 1)..to_index] || []
      changes = changes.select { |item| matches_filters?(item, actor: actor, source: source) }
      changes = limited(changes, limit)
      {
        status: "ok",
        from: state_reference(from_activity, from_index),
        to: state_reference(to_activity, to_index),
        changes: {
          count: changes.length,
          added: object_ids(changes, %w[knowledge_added]),
          changed: object_ids(changes, %w[knowledge_changed]),
          archived: object_ids(changes, %w[knowledge_archived]),
          restored: object_ids(changes, %w[knowledge_restored]),
          activities: changes.map(&:id)
        }
      }
    end

    def all
      return @all if @all

      snapshot_digest = current_snapshot_digest
      key = activity_cache_key(snapshot_digest)
      cached = @cache.fetch(key, snapshot_digest: snapshot_digest)
      @all = if cached
               deserialize_activities(cached.value.fetch("activities"))
             else
               activities = (build_activities + build_dataset_activities)
                            .sort_by { |activity| [parse_time(activity.created_at), activity.id] }.freeze
               cache_activities(activities, key, snapshot_digest)
               activities
             end
    end

    private

    def successful_audits
      selected = @audit_log.events.select do |audit|
        audit["result"] == "success" && audit["replayed"] != true && !audit.fetch("changed_paths", []).empty?
      end
      @successful_audits ||= selected.each_with_index
        .sort_by { |(audit, index)| [parse_time(audit.fetch("timestamp")), index] }
        .map(&:first).freeze
    end

    def dataset_audits
      @dataset_audits ||= StructuredDataset::ActivityAdapter.new(vault_root: @vault_root).audits.freeze
    end

    def build_activities
      event_map = event_assignments
      proposal_map = proposal_assignments
      planner = ReversalPlanner.new(vault_root: @vault_root, audits: successful_audits)
      successful_audits.map do |audit|
        base_event = event_map.dig(audit.fetch("id"), :base)
        events = event_map.dig(audit.fetch("id"), :events) || []
        proposal_id = proposal_map[audit.fetch("id")]
        proposal = load_proposal(proposal_id)
        approval = proposal_id && @proposal_store.approval(proposal_id)
        privacy = restricted?(audit, proposal) ? "redacted" : "visible"
        objects = privacy == "redacted" ? [] : public_objects(audit)
        activity = Activity.new(
          id: activity_id(audit), type: activity_type(audit),
          summary: summary(audit, privacy), created_at: normalized_time(audit.fetch("timestamp")),
          source: activity_source(proposal, base_event), actor: audit["actor_id"] || approval&.fetch("actor_id", nil),
          proposal: proposal_id, events: events.map(&:id), affected_objects: objects,
          undo_available: false, restore_available: false, privacy: privacy, audit: audit
        )
        Activity.new(**activity_attributes(activity).merge(
          undo_available: planner.available?(activity, operation: :undo),
          restore_available: planner.available?(activity, operation: :restore)
        ))
      end
    end

    def build_dataset_activities
      dataset_events = orchestration_events.select { |event| event.type == "DatasetChanged" }
      dataset_audits.map do |audit|
        record = repository.find(audit.fetch("entity_ids").first)
        privacy = record.data["sensitivity"] == "restricted" ? "redacted" : "visible"
        action = audit.fetch("dataset_action")
        event = dataset_events.find do |candidate|
          candidate.payload["dataset_id"] == record.id && candidate.payload["action"] == action &&
            candidate.payload["row_id"].to_s == audit["row_id"].to_s
        end
        objects = if privacy == "redacted"
                    []
                  else
                    [{ id: record.id, kind: "dataset", name: record.data["name"], state: "active" }]
                  end
        Activity.new(
          id: activity_id(audit), type: dataset_activity_type(action),
          summary: dataset_summary(audit, privacy), created_at: normalized_time(audit.fetch("timestamp")),
          source: audit.fetch("source"), actor: audit["actor_id"], proposal: audit["proposal_id"],
          events: event ? [event.id] : [], affected_objects: objects,
          undo_available: false, restore_available: false, privacy: privacy, audit: audit
        )
      rescue KnowledgeGraph::Error
        nil
      end.compact
    end

    def dataset_activity_type(action)
      return "knowledge_added" if %w[create insert import].include?(action)
      return "knowledge_archived" if action == "delete"

      "knowledge_changed"
    end

    def dataset_summary(audit, privacy)
      return "A restricted dataset change was recorded." if privacy == "redacted"

      verbs = {
        "create" => "was registered", "insert" => "received a row", "update" => "had a row updated",
        "delete" => "had a row deleted", "import" => "received an import", "migrate" => "was migrated"
      }
      "#{audit.fetch('dataset_name')} #{verbs.fetch(audit.fetch('dataset_action'), 'changed')}."
    end

    def activity_attributes(activity)
      Activity::ATTRIBUTES.to_h { |name| [name, activity.public_send(name)] }
    end

    def event_assignments
      events = orchestration_events
      graph_events = events.select { |event| event.type == "GraphChanged" }
      audit_groups = successful_audits.group_by { |audit| audit_event_signature(audit) }
      event_groups = graph_events.group_by { |event| graph_event_signature(event) }
      audit_groups.each_with_object({}) do |(signature, audits), result|
        candidates = event_groups.fetch(signature, []).sort_by { |event| [event.timestamp, event.sequence] }
        audits.each_with_index do |audit, index|
          base = candidates[index]
          related = if base
                      [base] + events.select do |event|
                        event.causation_id == base.id && event.trace_id == base.trace_id
                      end
                    else
                      []
                    end
          result[audit.fetch("id")] = { base: base, events: related.sort_by(&:sequence) }
        end
      end
    rescue KnowledgeOrchestration::Error
      {}
    end

    def audit_event_signature(audit)
      [audit["run_id"].to_s, audit.fetch("intent_type"), audit.fetch("entity_ids", []).map(&:to_s).sort]
    end

    def graph_event_signature(event)
      [event.correlation_id.to_s, event.payload["intent_type"].to_s,
       Array(event.payload["entity_ids"]).map(&:to_s).sort]
    end

    def proposal_assignments
      @proposal_store.submissions.each_with_object({}) do |submission, result|
        proposal_id = submission.fetch("proposal_id")
        submission.fetch("results", []).each do |item|
          result[item.fetch("audit_id")] = proposal_id if item["status"] == "executed" && item["audit_id"]
        end
      end
    end

    def load_proposal(proposal_id)
      proposal_id && @proposal_store.load(proposal_id)
    rescue KnowledgeExtraction::ProposalNotFound
      nil
    end

    def activity_id(audit)
      "activity_#{audit.fetch('id').split('_', 2).last}"
    end

    def activity_type(audit)
      case audit.fetch("intent_type")
      when "CreateEntity", "CreateMeeting", "RecordInteraction", "RecordPromise", "AddRelationship"
        "knowledge_added"
      when "ArchiveEntity", "RemoveRelationship" then "knowledge_archived"
      when "RestoreEntity" then "knowledge_restored"
      else "knowledge_changed"
      end
    end

    def summary(audit, privacy)
      return "A restricted knowledge change was recorded." if privacy == "redacted"

      type = audit.fetch("intent_type")
      params = audit.dig("intent", "params") || {}
      ids = audit.fetch("entity_ids", [])
      case type
      when "CreateEntity", "CreateMeeting", "RecordInteraction", "RecordPromise"
        "#{created_name(params, ids.first)} was added."
      when "UpdateEntity" then "#{name_for(params["entity_id"])} was updated."
      when "RenameEntity" then "#{name_for(params["entity_id"])} was renamed."
      when "ArchiveEntity" then "#{name_for(params["entity_id"])} was archived."
      when "RestoreEntity" then "#{name_for(params["entity_id"])} was restored."
      when "AddRelationship"
        "#{name_for(params["source"])} was connected to #{name_for(params["target"])}."
      when "RemoveRelationship" then "#{name_for(params["relationship_id"])} was archived."
      when "ReplaceRelationship" then "#{name_for(params["relationship_id"])} was changed."
      else "Knowledge was changed."
      end
    end

    def created_name(params, entity_id)
      attributes = params["attributes"] || {}
      attributes["name"] || name_for(entity_id)
    end

    def name_for(reference)
      return "Knowledge" if reference.nil? || reference.to_s.empty?

      record = repository.find(reference)
      return record.data["name"] if record.data["name"]
      if record.type == "relationship"
        predicate = record.data.fetch("predicate").tr("_", " ")
        return "#{name_for(record.data['subject_id'])} #{predicate} #{name_for(record.data['object_id'])}"
      end
      record.id
    rescue KnowledgeGraph::Error
      reference.to_s
    end

    def public_objects(audit)
      audit.fetch("entity_ids", []).map do |id|
        record = repository.find(id)
        {
          id: record.id, kind: record.type, name: record.data["name"],
          state: resulting_state(audit, record)
        }.reject { |_key, value| value.nil? }
      rescue KnowledgeGraph::Error
        { id: id, kind: "knowledge" }
      end.compact
    end

    def resulting_state(audit, record)
      case audit.fetch("intent_type")
      when "CreateEntity", "CreateMeeting", "RecordInteraction", "RecordPromise", "RestoreEntity"
        "active"
      when "AddRelationship", "ReplaceRelationship" then "asserted"
      when "ArchiveEntity" then "archived"
      when "RemoveRelationship" then "retracted"
      else
        record.type == "relationship" ? record.data["relationship_status"] : record.data["record_status"]
      end
    end

    def restricted?(audit, proposal)
      params = audit.dig("intent", "params") || {}
      return true if params.dig("attributes", "sensitivity") == "restricted"
      return true if proposal&.dig("source", "metadata", "sensitivity") == "restricted"

      audit.fetch("entity_ids", []).any? { |id| restricted_record?(repository.find(id)) }
    rescue KnowledgeGraph::Error
      false
    end

    def restricted_record?(record)
      return true if record.data["sensitivity"] == "restricted"
      return false unless record.type == "relationship"

      [record.data["subject_id"], record.data["object_id"]].compact.any? do |id|
        repository.find(id).data["sensitivity"] == "restricted"
      end
    end

    def activity_source(proposal, event)
      source = proposal&.fetch("source", nil)
      metadata = source&.fetch("metadata", {}) || {}
      metadata["observation_source"] || metadata["originating_source"] || source&.fetch("source_type", nil) ||
        event&.source || "knowledge-graph-engine"
    end

    def public_evidence(proposal, activity)
      return [{ redacted: true }] if activity.privacy == "redacted"
      return [{ kind: "audit_receipt", reference: activity.audit.fetch("id") }] unless proposal

      proposal.fetch("facts", []).flat_map { |fact| fact.fetch("evidence", []) }.map do |item|
        {
          evidence_id: item["evidence_id"], source_id: item["source_id"],
          excerpt: item["excerpt"] || item["quote"] || item["value"]
        }.reject { |_key, value| value.nil? }
      end
    end

    def public_proposal(proposal)
      return { status: "not_applicable" } unless proposal

      {
        id: proposal.fetch("proposal_id"), status: proposal.fetch("status"),
        summary: proposal.fetch("summary"), pipeline: proposal.fetch("pipeline_version")
      }
    end

    def public_approval(approval)
      return { status: "not_required_or_not_recorded" } unless approval

      {
        status: "approved", actor: approval.fetch("actor_id"),
        time: approval.fetch("approved_at"), approved_change_count: approval.fetch("approved_intent_ids").length
      }
    end

    def current_snapshot_digest
      KnowledgeOrchestration::Stable.digest(
        [KnowledgeIntelligence::GraphSnapshot.load(vault_root: @vault_root).digest,
         dataset_audits.map { |audit| audit.fetch("fingerprint") }]
      )
    end

    def activity_cache_key(snapshot_digest)
      @cache.key(
        capability_id: "kg.activity.timeline", capability_version: KnowledgeActivity::VERSION,
        arguments: {
          "audit_history" => KnowledgeOrchestration::Stable.digest(
            successful_audits.map { |audit| [audit.fetch("id"), audit.fetch("fingerprint")] }
          ),
          "dataset_history" => KnowledgeOrchestration::Stable.digest(
            dataset_audits.map { |audit| [audit.fetch("id"), audit.fetch("fingerprint")] }
          ),
          "proposal_history" => KnowledgeOrchestration::Stable.digest(@proposal_store.submissions),
          "event_history" => KnowledgeOrchestration::Stable.digest(
            activity_event_history.map { |event| [event.id, event.sequence] }
          )
        },
        snapshot_digest: snapshot_digest
      )
    end

    def cache_activities(activities, key, snapshot_digest)
      dependencies = KnowledgeOrchestration::ArtifactDependencies.new(
        event_ids: activities.flat_map(&:events),
        event_types: %w[GraphChanged RelationshipUpdated ContactCreated DatasetChanged],
        entity_ids: [], snapshot_digest: snapshot_digest,
        capability_id: "kg.activity.timeline", capability_version: KnowledgeActivity::VERSION
      )
      @cache.write(
        artifact_type: "activity", cache_key: key,
        value: {
          "activities" => activities.map do |activity|
            activity.to_h.merge("audit_id" => activity.audit.fetch("id"))
          end
        },
        dependencies: dependencies, metadata: { "activity_count" => activities.length }
      )
    end

    def deserialize_activities(items)
      audits = (successful_audits + dataset_audits).to_h { |audit| [audit.fetch("id"), audit] }
      items.map do |item|
        data = AgentPlatform::Value.mutable(item)
        audit_id = data.delete("audit_id")
        audit = audits.fetch(audit_id) { raise KnowledgeOrchestration::CacheError, "cached activity audit is unavailable" }
        attributes = Activity::ATTRIBUTES.each_with_object({}) do |name, result|
          result[name] = name == :audit ? audit : data[name.to_s]
        end
        Activity.new(**attributes)
      end.freeze
    end

    def activity_event_history
      graph_events = orchestration_events.select { |event| event.type == "GraphChanged" }
      graph_by_id = graph_events.to_h { |event| [event.id, event] }
      graph_events + orchestration_events.select do |event|
        base = graph_by_id[event.causation_id]
        base && event.trace_id == base.trace_id
      end + orchestration_events.select { |event| event.type == "DatasetChanged" }
    end

    def orchestration_events
      @orchestration_events ||= @event_store.events
    end

    def filtered(actor:, source:)
      all.select { |activity| matches_filters?(activity, actor: actor, source: source) }
    end

    def matches_filters?(activity, actor:, source:)
      actor_match = actor.nil? || activity.actor.to_s.casecmp?(actor.to_s)
      source_match = source.nil? || activity.source.to_s.casecmp?(source.to_s)
      actor_match && source_match
    end

    def select_time(from_time:, to_time: nil, limit:, actor:, source:)
      matches = filtered(actor: actor, source: source).select do |activity|
        timestamp = parse_time(activity.created_at)
        timestamp >= from_time && (!to_time || timestamp < to_time)
      end.reverse
      limited(matches, limit)
    end

    def searchable(activity)
      JSON.generate(activity.to_h)
    end

    def limited(items, limit)
      return items if limit.nil?

      value = Integer(limit)
      raise InvalidActivityQuery, "--limit must be positive" unless value.positive?

      items.first(value)
    rescue ArgumentError, TypeError
      raise InvalidActivityQuery, "--limit must be a positive integer"
    end

    def parse_time(value)
      return value if value.is_a?(Time)
      Time.parse(value.to_s)
    rescue ArgumentError
      raise InvalidActivityQuery, "time must be ISO 8601"
    end

    def normalized_time(value)
      parse_time(value).iso8601
    end

    def local_day_start(value)
      local = value.getlocal
      Time.new(local.year, local.month, local.day, 0, 0, 0, local.utc_offset)
    end

    def state_reference(activity, index)
      {
        activity_id: activity.id, time: activity.created_at,
        state_digest: KnowledgeOrchestration::Stable.digest(
          successful_audits.first(index + 1).map { |audit| audit.fetch("fingerprint") }
        )
      }
    end

    def object_ids(changes, types)
      changes.select { |activity| types.include?(activity.type) }
        .flat_map(&:affected_objects).map { |item| item.fetch("id") }.uniq.sort
    end

    def proposal_adapter
      @proposal_adapter ||= ProposalAdapter.new(
        vault_root: @vault_root, audits: successful_audits, clock: @clock, event_bus: @event_bus
      )
    end

    def repository
      @repository ||= KnowledgeGraph::Repository.new(vault_root: @vault_root, registry: schema_registry)
    end

    def schema_registry
      @schema_registry ||= KnowledgeGraph::SchemaRegistry.new(vault_root: @vault_root)
    end
  end
end
