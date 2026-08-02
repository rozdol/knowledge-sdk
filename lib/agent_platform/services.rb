# frozen_string_literal: true

require "date"

module AgentPlatform
  class Services
    attr_reader :vault_root, :run_id, :actor_id

    def initialize(vault_root:, run_id:, actor_id: nil, clock: nil, event_bus: nil,
                   notification_store: nil)
      @vault_root = File.expand_path(vault_root.to_s).freeze
      @run_id = run_id.to_s.freeze
      @actor_id = actor_id && actor_id.to_s.freeze
      @clock = clock || -> { Time.now }
      @event_bus = event_bus
      @notification_store = notification_store
    end

    def graph_reader(context)
      context.memoize(:graph_reader) { KnowledgeGraph::GraphReader.new(vault_root: vault_root) }
    end

    def snapshot(context)
      context.memoize(:graph_snapshot) { KnowledgeIntelligence::GraphSnapshot.load(vault_root: vault_root) }
    end

    def proposal_store(context = nil)
      return context.memoize(:proposal_store) { KnowledgeExtraction::ProposalStore.new(vault_root: vault_root) } if context

      KnowledgeExtraction::ProposalStore.new(vault_root: vault_root)
    end

    def analysis(context, names: nil, analyzer_config: {}, as_of: nil)
      date = parse_date(as_of)
      key = ["analysis", Array(names).map(&:to_s).sort, Value.canonical_json(analyzer_config), date.iso8601]
      context.memoize(key) do
        KnowledgeIntelligence::AnalysisEngine.new(
          snapshot: snapshot(context), analyzers: KnowledgeIntelligence::DefaultAnalyzers.build,
          as_of: date, analyzer_config: symbolize_keys(analyzer_config)
        ).run(names: names)
      end
    end

    def feature_engine(context, as_of: nil)
      date = parse_date(as_of)
      context.memoize(["features", date.iso8601]) do
        KnowledgeIntelligence::FeatureEngine.new(
          snapshot: snapshot(context), registry: KnowledgeIntelligence::DefaultFeatures.registry,
          as_of: date
        )
      end
    end

    def planning(context, goal:, as_of: nil)
      date = parse_date(as_of)
      key = ["planning", KnowledgePlanning::Stable.json(goal.planning_signature), date.iso8601]
      context.memoize(key) do
        KnowledgePlanning::Engine.new(
          snapshot: snapshot(context), as_of: date,
          dataset_provider: StructuredDataset::PlanningAdapter.new(engine: dataset_engine(context), clock: @clock)
        ).plan(goal)
      end
    end

    def extraction_pipeline(context)
      context.memoize(:extraction_pipeline) do
        reader = graph_reader(context)
        provider = KnowledgeExtraction::DeterministicExtractionProvider.new
        configuration = KnowledgeExtraction::Configuration.new(
          provider_name: provider.name, allowed_entity_types: reader.entity_types,
          allowed_predicates: reader.predicates, external_provider_enabled: false
        )
        KnowledgeExtraction::KnowledgeExtractionPipeline.new(
          graph_reader: reader, provider: provider, configuration: configuration,
          proposal_store: proposal_store(context)
        )
      end
    end

    def engine(context)
      context.memoize(:engine) do
        engine = KnowledgeGraph::Engine.new(
          vault_root: vault_root, run_id: run_id, actor_id: actor_id, clock: @clock
        )
        if @event_bus
          KnowledgeOrchestration::EngineEventBridge.new(event_bus: @event_bus).attach(engine)
        end
        engine
      end
    end

    def dataset_engine(context)
      context.memoize(:dataset_engine) do
        StructuredDataset::Engine.new(
          vault_root: vault_root, run_id: run_id, actor_id: actor_id,
          event_bus: @event_bus, clock: @clock
        )
      end
    end

    def dataset_proposal_builder(context)
      context.memoize(:dataset_proposal_builder) do
        StructuredDataset::DatasetProposalBuilder.new(
          vault_root: vault_root, proposal_store: proposal_store(context),
          classifier: KnowledgeGraph::ChatIntentResolver.classifier,
          event_bus: @event_bus, clock: @clock
        )
      end
    end

    def cross_analysis(context, question:, from: nil, to: nil, as_of: nil,
                       propose_recommendations: false)
      key = ["cross-analysis", question.to_s, from.to_s, to.to_s, as_of.to_s, !!propose_recommendations]
      context.memoize(key) do
        KnowledgeAnalysis::Engine.new(
          vault_root: vault_root, dataset_engine: dataset_engine(context),
          snapshot: snapshot(context), event_bus: @event_bus, clock: @clock
        ).analyze(
          question, from: from, to: to, as_of: as_of,
          propose_recommendations: propose_recommendations
        )
      end
    end

    def notification_store
      raise ExecutionFailed, "notification service is unavailable" unless @notification_store

      @notification_store
    end

    def notification_store?
      !@notification_store.nil?
    end

    def visible_entity?(record, agent)
      sensitivity = record.respond_to?(:sensitivity) ? record.sensitivity : record["sensitivity"]
      sensitivity != "restricted" || agent.permits?("graph:restricted")
    end

    def public_entity(record, agent)
      return nil unless record && visible_entity?(record, agent)

      if record.respond_to?(:attributes)
        value = {
          id: record.id, type: record.type, name: record.name, aliases: record.aliases,
          record_status: record.record_status, attributes: record.attributes
        }
        if agent.permits?("graph:private")
          value[:emails] = record.emails
          value[:phones] = record.phones
        end
      else
        value = {
          id: record.id, type: record.type, name: record.name,
          aliases: Array(record["aliases"]), record_status: record["record_status"]
        }
      end
      SecurityGuard.sanitize(value)
    end

    def public_evidence(evidence, context = nil)
      return nil if context && restricted_ids(context).include?(evidence.record_id)

      {
        evidence_id: evidence.evidence_id, record_id: evidence.record_id,
        field: evidence.field, role: evidence.role
      }.reject { |_key, value| value.nil? }
    end

    def visible_finding?(finding, context)
      (finding.entity_ids + finding.graph_path).none? { |id| restricted_ids(context).include?(id) } &&
        finding.evidence.none? { |item| restricted_ids(context).include?(item.record_id) }
    end

    def visible_findings(findings, context)
      Array(findings).select { |finding| visible_finding?(finding, context) }
    end

    def public_finding(finding, context = nil)
      return nil if context && !visible_finding?(finding, context)

      {
        finding_id: finding.finding_id, analyzer: finding.analyzer, kind: finding.kind,
        title: finding.title, entity_ids: finding.entity_ids, confidence: finding.confidence,
        evidence: finding.evidence.map { |item| public_evidence(item, context) }.compact,
        explanation: finding.explanation, severity: finding.severity,
        priority: finding.priority, tags: finding.tags, graph_path: finding.graph_path,
        features: context ? public_value(finding.features, context) || {} : SecurityGuard.sanitize(finding.features),
        details: context ? public_value(finding.details, context) || {} : SecurityGuard.sanitize(finding.details),
        proposal_ids: finding.intent_proposals.map(&:proposal_id)
      }
    end

    def public_analysis(run_result, context)
      {
        snapshot_digest: run_result.snapshot_digest, as_of: run_result.as_of,
        results: run_result.results.map do |result|
          {
            analyzer: result.analyzer, version: result.version,
            findings: visible_findings(result.findings, context).map { |finding| public_finding(finding, context) },
            metrics: public_value(result.metrics, context) || {}
          }
        end,
        feature_metrics: public_value(run_result.feature_metrics, context) || {}
      }
    end

    def public_report(report, context)
      sections = public_value(report.sections, context) || {}
      visible_count = sections.values.sum { |value| value.is_a?(Array) ? value.length : 0 }
      {
        name: report.name, as_of: report.as_of,
        summary: "#{visible_count} policy-visible digest items across #{sections.length} sections.",
        sections: sections, metrics: public_value(report.metrics, context) || {}
      }
    end

    def visible_plan?(ranked_plan, context)
      hidden = restricted_ids(context)
      plan = ranked_plan.plan
      entity_ids = Array(plan.metadata["entity_ids"]) + plan.steps.flat_map(&:entity_ids)
      evidence_ids = plan.evidence.map(&:record_id)
      intent_ids = nested_strings(plan.generated_intents).map do |value|
        snapshot(context).resolve_link(value)
      end.compact
      ((entity_ids + evidence_ids + intent_ids).map(&:to_s).uniq & hidden).empty?
    end

    def public_planning_result(result, context)
      payload = Value.mutable(result.to_h)
      visible = result.ranked_plans.select { |item| visible_plan?(item, context) }
      visible_ids = visible.map { |item| item.plan.plan_id }
      payload["ranked_plans"].select! do |item|
        visible_ids.include?(item.dig("scenario", "plan", "plan_id"))
      end
      approved_id = result.approved_plan && result.approved_plan.plan.plan_id
      payload["approved_plan"] = nil unless visible_ids.include?(approved_id)
      trace = payload.fetch("decision_trace")
      trace.fetch("candidate_generation")["candidate_plan_ids"] &= visible_ids
      trace["scenario_evaluation"].select! { |item| visible_ids.include?(item["plan_id"]) }
      decision = trace.fetch("decision")
      decision["pareto_plan_ids"] &= visible_ids
      decision["ranking"].select! { |item| visible_ids.include?(item["plan_id"]) }
      decision["chosen_plan_id"] = nil unless visible_ids.include?(decision["chosen_plan_id"])
      SecurityGuard.sanitize(public_value(payload, context) || {})
    end

    def public_value(value, context)
      hidden = restricted_ids(context)
      case value
      when Hash
        normalized = Value.mutable(value)
        direct_ids = %w[id record_id subject_id object_id introducer_id person_a_id person_b_id].map do |key|
          normalized[key]
        end.compact
        referenced = Array(normalized["entity_ids"]) + Array(normalized["graph_path"]) + direct_ids
        return nil unless (referenced & hidden).empty?

        normalized.each_with_object({}) do |(key, item), result|
          next if hidden.include?(key.to_s)

          public_item = public_value(item, context)
          result[key.to_s] = public_item unless public_item.nil? && !item.nil?
        end
      when Array
        value.map { |item| public_value(item, context) }.compact
      when String
        hidden.include?(value) ? nil : value
      else
        SecurityGuard.sanitize(value)
      end
    end

    def parse_date(value)
      return @clock.call.to_date if value.nil? || value.to_s.empty?
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue ArgumentError
      raise InvalidArguments, "as_of must be an ISO 8601 date"
    end

    private

    def restricted_ids(context)
      return [] if context.agent.permits?("graph:restricted")

      context.memoize(:restricted_entity_ids) do
        snapshot(context).records(active_only: false).select do |record|
          record["sensitivity"] == "restricted"
        end.map(&:id).freeze
      end
    end

    def symbolize_keys(value)
      value.each_with_object({}) { |(key, item), result| result[key.to_sym] = item }
    end

    def nested_strings(value)
      case value
      when Hash then value.flat_map { |key, item| [key.to_s] + nested_strings(item) }
      when Array then value.flat_map { |item| nested_strings(item) }
      when String then [value]
      else []
      end
    end
  end
end
