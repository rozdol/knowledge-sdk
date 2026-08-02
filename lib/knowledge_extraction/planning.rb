# frozen_string_literal: true

require "digest"

module KnowledgeExtraction
  class RiskClassifier
    HIGH_RISK = %w[
      MergeEntities SplitEntity RemoveRelationship RenameEntity ArchiveEntity ReplaceRelationship
    ].freeze
    MEDIUM_RISK = %w[
      UpdateEntity RecordPromise CompleteFollowUp InsertDatasetRow CreateMedicationSchedule
      ReplaceMedicationSchedule PauseMedicationSchedule ResumeMedicationSchedule StopMedication
      ModifyMedicationDose ModifyMedicationSchedule
      InsertBloodPressureMeasurement InsertWeightMeasurement InsertBloodTestResult
      InsertBodyMeasurement InsertExpense CreateDataset UpgradeDatasetSchema
    ].freeze

    def classify(intent)
      return "high" if HIGH_RISK.include?(intent.intent_type)
      if intent.is_a?(KnowledgeGraph::UpdateEntity) &&
         !(intent.changes.keys.map(&:to_s) & %w[emails phones external_ids primary_email primary_phone is_self]).empty?
        return "high"
      end
      return "medium" if MEDIUM_RISK.include?(intent.intent_type)
      return "medium" if intent.is_a?(KnowledgeGraph::CreateEntity) && %w[person organization].include?(intent.entity_type)
      return "medium" if intent.is_a?(KnowledgeGraph::CreateEntity) && intent.entity_type == "follow-up"
      return "medium" if intent.is_a?(KnowledgeGraph::CreateEntity) &&
                         KnowledgeGraph::EntityManager::APPROVAL_GATED_TYPES.include?(intent.entity_type)

      "low"
    end

    def approval_requirement(intent, risk, configuration)
      engine_gate = intent.respond_to?(:human_approved) &&
                    (!intent.respond_to?(:entity_type) ||
                     KnowledgeGraph::EntityManager::APPROVAL_GATED_TYPES.include?(intent.entity_type) ||
                     %w[MergeEntities SplitEntity].include?(intent.intent_type))
      return "explicit_engine_approval" if engine_gate
      return "none" if risk == "low" && configuration.approval_policy == "allow_low_risk"

      "human_review"
    end
  end

  class PlannedIntent < ImmutableModel
    attr_reader :planned_intent_id, :intent, :idempotency_key, :fact_ids,
                :evidence_ids, :planning_confidence, :risk, :approval_requirement,
                :dependencies, :blocked_reasons, :provenance, :local_references,
                :safe_dependency_group

    def initialize(planned_intent_id:, intent:, fact_ids:, evidence_ids:,
                   planning_confidence:, risk:, approval_requirement:, dependencies: [],
                   blocked_reasons: [], provenance:, local_references: {},
                   safe_dependency_group: nil, idempotency_key: nil)
      unless intent.is_a?(KnowledgeGraph::Intent)
        raise PlanningFailure, "planned operation must use a KnowledgeGraph::Intent"
      end
      @planned_intent_id = required_string(planned_intent_id, "planned_intent_id", maximum: 200)
      @intent = intent
      @idempotency_key = (idempotency_key || Digest::SHA256.hexdigest(
        Support.canonical_json(intent.to_h.merge(provenance: provenance))
      )).to_s.freeze
      @fact_ids = immutable(Array(fact_ids).map(&:to_s).uniq.sort)
      @evidence_ids = immutable(Array(evidence_ids).map(&:to_s).uniq.sort)
      raise PlanningFailure, "planned Intent requires fact provenance" if @fact_ids.empty?
      raise PlanningFailure, "planned Intent requires evidence provenance" if @evidence_ids.empty?
      @planning_confidence = validated_confidence(planning_confidence, "planning_confidence")
      @risk = risk.to_s.freeze
      raise PlanningFailure, "invalid risk #{@risk.inspect}" unless %w[low medium high].include?(@risk)
      @approval_requirement = required_string(approval_requirement, "approval_requirement", maximum: 100)
      @dependencies = immutable(Array(dependencies).map(&:to_s).uniq.sort)
      @blocked_reasons = immutable(Array(blocked_reasons).map(&:to_s))
      @provenance = immutable(provenance)
      @local_references = immutable(local_references)
      @safe_dependency_group = (safe_dependency_group || @planned_intent_id).to_s.freeze
      freeze
    end

    def blocked?
      !blocked_reasons.empty?
    end

    def to_h
      parameters = intent.to_h.dup
      type = parameters.delete(:intent_type)
      {
        planned_intent_id: planned_intent_id,
        intent: { type: type, params: parameters }, idempotency_key: idempotency_key,
        fact_ids: fact_ids, evidence_ids: evidence_ids,
        planning_confidence: planning_confidence, risk: risk,
        approval_requirement: approval_requirement, dependencies: dependencies,
        blocked_reasons: blocked_reasons, provenance: provenance,
        local_references: local_references, safe_dependency_group: safe_dependency_group
      }
    end
  end

  class PlanningResult < ImmutableModel
    attr_reader :planned_intents, :warnings, :rejected_items

    def initialize(planned_intents:, warnings:, rejected_items:)
      @planned_intents = immutable(planned_intents)
      @warnings = immutable(warnings)
      @rejected_items = immutable(rejected_items)
      validate_dependencies!
      freeze
    end

    def to_h
      {
        planned_intents: planned_intents.map(&:to_h), warnings: warnings,
        rejected_items: rejected_items.map(&:to_h)
      }
    end

    private

    def validate_dependencies!
      ids = planned_intents.map(&:planned_intent_id)
      raise PlanningFailure, "duplicate planned Intent IDs" unless ids.uniq.length == ids.length
      missing = planned_intents.flat_map(&:dependencies).uniq - ids
      raise PlanningFailure, "missing Intent dependencies: #{missing.join(', ')}" unless missing.empty?

      visiting = {}
      visited = {}
      by_id = planned_intents.to_h { |item| [item.planned_intent_id, item] }
      visit = lambda do |id|
        raise PlanningFailure, "cyclic Intent dependency at #{id}" if visiting[id]
        return if visited[id]

        visiting[id] = true
        by_id.fetch(id).dependencies.each { |dependency| visit.call(dependency) }
        visiting.delete(id)
        visited[id] = true
      end
      ids.each { |id| visit.call(id) }
    end
  end

  class IntentPlanner
    ID_PREFIXES = {
      "person" => "person", "organization" => "org", "interest" => "interest",
      "technology" => "technology", "industry" => "industry", "profession" => "profession",
      "language" => "language", "project" => "project", "place" => "place",
      "event" => "event", "book" => "book", "country" => "country", "city" => "city"
    }.freeze
    ATTRIBUTE_ALLOWLIST = {
      "person" => %w[
        legal_name former_names nicknames transliterations emails primary_email phones primary_phone
        external_ids birth_date pronouns life_status contact_policy cadence_target_days preferred_channel
        timezone review_on
      ],
      "organization" => %w[legal_name former_names domains external_ids founded_on closed_on company_stage website],
      "project" => %w[project_status started_on target_end_on ended_on website]
    }.freeze
    RELATIONSHIP_QUALIFIERS = %w[
      valid_from valid_to observed_on context_links source_links source_urls confidence sensitivity data_origin
    ].freeze

    def initialize(graph_reader:, configuration: Configuration.new, risk_classifier: RiskClassifier.new)
      @graph_reader = graph_reader
      @configuration = configuration
      @risk_classifier = risk_classifier
    end

    def plan(document:, extraction:, resolutions:)
      decisions = resolutions.to_h { |decision| [decision.mention_id, decision] }
      facts_by_mention = index_facts(extraction.facts)
      planned = []
      rejected = []
      warnings = []
      creations = plan_creations(document, extraction.mentions, facts_by_mention, decisions, planned, rejected)
      extraction.facts.each do |fact|
        if fact.confidence < @configuration.minimum_fact_confidence
          rejected << rejection(fact, "fact confidence below planning threshold", "intent_planning")
          next
        end
        unless %w[asserted historical].include?(fact.status)
          rejected << rejection(fact, "#{fact.status} facts are preserved for review but not planned", "intent_planning")
          next
        end

        case fact.fact_type
        when "entity" then next
        when "relationship"
          item = plan_relationship(document, fact, decisions, creations)
        when "attribute"
          item = plan_attribute(document, fact, decisions, creations)
        when "meeting", "interaction"
          item = plan_interaction(document, fact, decisions)
        when "promise"
          item = plan_promise(document, fact, decisions)
        when "follow-up"
          item = plan_follow_up(document, fact, decisions)
        when "dataset_observation"
          item = plan_dataset_observation(document, fact, decisions)
        else
          item = blocked_intent(document, fact, "No safe existing Intent mapping for #{fact.fact_type}")
        end
        if item
          planned << item
          warnings.concat(item.blocked_reasons.map { |reason| "#{item.planned_intent_id}: #{reason}" })
        end
      rescue StandardError => error
        rejected << rejection(fact, error.message, "intent_planning")
      end
      PlanningResult.new(planned_intents: planned, warnings: warnings.uniq, rejected_items: rejected)
    end

    private

    def index_facts(facts)
      result = Hash.new { |hash, key| hash[key] = [] }
      facts.each do |fact|
        result[fact.subject.mention_id] << fact
        result[fact.object.mention_id] << fact if fact.object.is_a?(EntityMention)
      end
      result
    end

    def plan_creations(document, mentions, facts_by_mention, decisions, planned, rejected)
      creations = {}
      mentions.each do |mention|
        decision = decisions.fetch(mention.mention_id)
        next unless decision.outcome == "new_entity"

        supporting = facts_by_mention.fetch(mention.mention_id, []).select do |fact|
          %w[asserted historical].include?(fact.status) &&
            fact.confidence >= @configuration.minimum_fact_confidence
        end
        confidence_value = supporting.map(&:confidence).max || 0.0
        if confidence_value < @configuration.minimum_fact_confidence
          rejected << RejectedItem.new(
            item: mention.to_h, reason: "mention lacks a plannable supporting fact", stage: "intent_planning"
          )
          next
        end
        attributes = default_attributes(mention)
        unless attributes
          rejected << RejectedItem.new(
            item: mention.to_h, reason: "new #{mention.entity_type} needs fields unavailable from evidence",
            stage: "intent_planning"
          )
          next
        end
        prefix = ID_PREFIXES.fetch(mention.entity_type)
        entity_id = Support.deterministic_ulid(prefix, document.captured_at, document.source_id, mention.mention_id)
        attributes[:id] = entity_id
        intent = KnowledgeGraph::CreateEntity.new(
          entity_type: mention.entity_type, attributes: attributes,
          human_approved: false,
          intent_id: Support.stable_id("intent", document.source_id, "create", mention.mention_id)
        )
        facts = supporting
        item = build_planned(
          document, intent, facts, confidence_value,
          local_references: { mention.mention_id => entity_id }
        )
        planned << item
        creations[mention.mention_id] = { entity_id: entity_id, planned_intent_id: item.planned_intent_id }
      end
      creations
    end

    def default_attributes(mention)
      common = { name: mention.display_name, aliases: mention.aliases }
      case mention.entity_type
      when "person"
        common.merge(
          tier: "active", sensitivity: "private", data_origin: "inferred",
          emails: mention.email ? [mention.email] : [], phones: mention.phone ? [mention.phone] : [],
          external_ids: mention.external_ids
        )
      when "organization" then common.merge(org_kind: "company")
      when "interest" then common.merge(interest_kind: "topic")
      when "technology" then common.merge(technology_kind: "product")
      when "industry", "profession", "language" then common
      when "project" then common.merge(project_status: "planned")
      when "place" then common.merge(place_kind: "venue")
      else nil
      end
    end

    def plan_relationship(document, fact, decisions, creations)
      unless @graph_reader.predicates.include?(fact.predicate) && allowed_predicate?(fact.predicate)
        raise UnsupportedIntentMapping, "unsupported relationship predicate #{fact.predicate.inspect}"
      end
      unless fact.object.is_a?(EntityMention)
        raise UnsupportedIntentMapping, "relationship object must be an entity mention"
      end
      source, source_dependency, source_score = endpoint(fact.subject, decisions, creations)
      target, target_dependency, target_score = endpoint(fact.object, decisions, creations)
      blocked = []
      blocked << "subject identity requires resolution" unless source
      blocked << "object identity requires resolution" unless target
      if fact.status == "historical" && !fact.qualifiers.key?("valid_to") && !fact.qualifiers.key?(:valid_to)
        blocked << "historical relationship needs an explicit valid_to date"
      end
      source ||= "unresolved:#{fact.subject.mention_id}"
      target ||= "unresolved:#{fact.object.mention_id}"
      attributes = relationship_attributes(fact)
      if source.start_with?("unresolved:") || target.start_with?("unresolved:")
        intent = KnowledgeGraph::AddRelationship.new(source: source, predicate: fact.predicate, target: target, attributes: attributes)
      else
        definition = @graph_reader.predicate(fact.predicate)
        unless definition.fetch(:subject_types).include?(fact.subject.entity_type) &&
               definition.fetch(:object_types).include?(fact.object.entity_type)
          blocked << "predicate endpoint types do not match the graph registry"
        end
        blocked << "relationship already exists" if @graph_reader.relationship_exists?(
          source_id: source, predicate: fact.predicate, target_id: target
        )
        intent = KnowledgeGraph::AddRelationship.new(
          source: source, predicate: fact.predicate, target: target, attributes: attributes,
          intent_id: Support.stable_id("intent", document.source_id, fact.fact_id, "relationship")
        )
      end
      build_planned(
        document, intent, [fact], [fact.confidence, source_score, target_score].compact.min || 0.0,
        dependencies: [source_dependency, target_dependency].compact, blocked_reasons: blocked
      )
    end

    def plan_attribute(document, fact, decisions, creations)
      unless fact.object.is_a?(ScalarValue)
        raise UnsupportedIntentMapping, "attribute object must be scalar"
      end
      allowed = ATTRIBUTE_ALLOWLIST.fetch(fact.subject.entity_type, [])
      raise UnsupportedIntentMapping, "attribute #{fact.predicate.inspect} is not update-safe" unless allowed.include?(fact.predicate)

      entity_id, dependency, resolution_score = endpoint(fact.subject, decisions, creations)
      blocked = entity_id ? [] : ["subject identity requires resolution"]
      entity_id ||= "unresolved:#{fact.subject.mention_id}"
      value = fact.object.normalized_value.nil? ? fact.object.value : fact.object.normalized_value
      intent = KnowledgeGraph::UpdateEntity.new(
        entity_id: entity_id, changes: { fact.predicate => value },
        intent_id: Support.stable_id("intent", document.source_id, fact.fact_id, "attribute")
      )
      build_planned(
        document, intent, [fact], [fact.confidence, resolution_score].compact.min || 0.0,
        dependencies: [dependency].compact, blocked_reasons: blocked
      )
    end

    def plan_interaction(document, fact, decisions)
      participants = Array(fact.qualifiers["participants"] || fact.qualifiers[:participants])
      links = participants.map do |mention_id|
        decision = decisions[mention_id.to_s]
        decision&.outcome == "resolved" ? @graph_reader.find(decision.selected_entity_id).link : nil
      end
      blocked = []
      blocked << "interaction participants require canonical entity resolution" if links.any?(&:nil?) || links.length < 2
      starts_at = fact.qualifiers["starts_at"] || fact.qualifiers[:starts_at] || document.captured_at&.iso8601
      blocked << "interaction requires an exact starts_at value" unless starts_at
      attributes = {
        name: scalar_text(fact.object), starts_at: starts_at, participants: links.compact,
        sensitivity: "private", data_origin: "inferred"
      }
      intent = if fact.fact_type == "meeting"
                 KnowledgeGraph::CreateMeeting.new(attributes: attributes)
               else
                 attributes[:interaction_kind] = fact.qualifiers["interaction_kind"] || "message"
                 attributes[:contact_weight] = fact.qualifiers["contact_weight"] || "substantive"
                 KnowledgeGraph::RecordInteraction.new(attributes: attributes)
               end
      build_planned(document, intent, [fact], fact.confidence, blocked_reasons: blocked)
    end

    def plan_promise(document, fact, decisions)
      blocked = ["promise roles require explicit structured role mappings"]
      intent = KnowledgeGraph::RecordPromise.new(
        attributes: {
          name: scalar_text(fact.object), action: scalar_text(fact.object),
          made_on: document.captured_at&.to_date&.iso8601,
          sensitivity: "private", data_origin: "inferred"
        }
      )
      build_planned(document, intent, [fact], fact.confidence, blocked_reasons: blocked)
    end

    def plan_follow_up(document, fact, _decisions)
      owner = @graph_reader.self_entity
      blocked = []
      blocked << "no canonical Self entity is available" unless owner
      due = fact.qualifiers["due_on"] || fact.qualifiers[:due_on]
      attributes = {
        name: scalar_text(fact.object), owner: owner&.link || "unresolved:self",
        action: scalar_text(fact.object), followup_status: "open",
        sensitivity: "private", data_origin: "inferred"
      }
      attributes[:due_on] = due if due
      intent = KnowledgeGraph::CreateEntity.new(entity_type: "follow-up", attributes: attributes)
      build_planned(document, intent, [fact], fact.confidence, blocked_reasons: blocked)
    end

    def plan_dataset_observation(document, fact, decisions)
      unless fact.object.is_a?(ScalarValue) && fact.object.value.is_a?(Hash)
        raise UnsupportedIntentMapping, "dataset observation requires structured scalar values"
      end
      decision = decisions.fetch(fact.subject.mention_id)
      blocked = []
      blocked << "observation subject must resolve to canonical Self" unless decision.outcome == "resolved"
      self_entity = @graph_reader.self_entity
      blocked << "observation subject does not match canonical Self" if self_entity && decision.selected_entity_id != self_entity.id
      matches = @graph_reader.search(fact.predicate.tr("_", " "), entity_type: "dataset")
      blocked << "target Dataset must exist in the graph registry" if matches.empty?
      values = fact.object.normalized_value || fact.object.value
      intent = KnowledgeGraph::InsertDatasetRow.new(
        dataset: fact.predicate, values: values,
        source: document.source_type,
        observation_id: document.metadata["observation_id"] || document.source_id,
        intent_id: Support.stable_id("intent", document.source_id, fact.fact_id, "dataset-row")
      )
      confidence = [fact.confidence, decision.selected_candidate&.score].compact.min || 0.0
      build_planned(document, intent, [fact], confidence, blocked_reasons: blocked)
    end

    def blocked_intent(document, fact, reason)
      placeholder = KnowledgeGraph::UpdateEntity.new(
        entity_id: "unresolved:#{fact.subject.mention_id}", changes: {},
        intent_id: Support.stable_id("intent", document.source_id, fact.fact_id, "blocked")
      )
      build_planned(document, placeholder, [fact], 0.0, blocked_reasons: [reason])
    end

    def endpoint(mention, decisions, creations)
      decision = decisions.fetch(mention.mention_id)
      if decision.outcome == "resolved"
        [decision.selected_entity_id, nil, decision.selected_candidate&.score || 1.0]
      elsif decision.outcome == "new_entity" && creations.key?(mention.mention_id)
        creation = creations.fetch(mention.mention_id)
        [creation.fetch(:entity_id), creation.fetch(:planned_intent_id), 0.90]
      else
        [nil, nil, 0.0]
      end
    end

    def relationship_attributes(fact)
      definition = @graph_reader.predicate(fact.predicate)
      allowed = RELATIONSHIP_QUALIFIERS + definition.fetch(:allowed_fields)
      attributes = {}
      fact.qualifiers.each do |key, value|
        string_key = key.to_s
        attributes[string_key] = value if allowed.include?(string_key)
      end
      attributes["confidence"] ||= confidence_band(fact.confidence)
      attributes["data_origin"] ||= fact.inference ? "inferred" : "third_party"
      attributes
    end

    def allowed_predicate?(predicate)
      @configuration.allowed_predicates.empty? || @configuration.allowed_predicates.include?(predicate)
    end

    def confidence_band(value)
      return "confirmed" if value >= 0.95
      return "probable" if value >= 0.80
      return "possible" if value >= 0.60

      "disputed"
    end

    def build_planned(document, intent, facts, planning_confidence, dependencies: [], blocked_reasons: [],
                      local_references: {})
      fact_ids = facts.map(&:fact_id)
      evidence_ids = facts.flat_map(&:evidence).map(&:evidence_id)
      planned_id = Support.stable_id(
        "planned", document.source_id, intent.intent_type, fact_ids.join("|"),
        Support.canonical_json(intent.to_h)
      )
      risk = @risk_classifier.classify(intent)
      approval = @risk_classifier.approval_requirement(intent, risk, @configuration)
      provenance = {
        source_id: document.source_id, source_hash: document.content_hash,
        fact_ids: fact_ids, evidence_ids: evidence_ids,
        pipeline_version: @configuration.pipeline_version,
        prompt_version: @configuration.prompt_version,
        resolution_decisions: facts.flat_map do |fact|
          values = [fact.subject.mention_id]
          values << fact.object.mention_id if fact.object.is_a?(EntityMention)
          values
        end.uniq,
        approval_classification: approval
      }
      PlannedIntent.new(
        planned_intent_id: planned_id, intent: intent, fact_ids: fact_ids,
        evidence_ids: evidence_ids, planning_confidence: planning_confidence,
        risk: risk, approval_requirement: approval, dependencies: dependencies,
        blocked_reasons: blocked_reasons, provenance: provenance,
        local_references: local_references
      )
    end

    def scalar_text(object)
      object.is_a?(ScalarValue) ? object.value.to_s : object.display_name
    end

    def rejection(fact, reason, stage)
      RejectedItem.new(item: fact.to_h, reason: reason, stage: stage)
    end
  end
end
