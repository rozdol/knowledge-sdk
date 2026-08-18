# frozen_string_literal: true

module AgentPlatform
  module DefaultHandlers
    module_function

    def build(services)
      registry = HandlerRegistry.new
      register_entity_handlers(registry, services)
      register_graph_handlers(registry, services)
      register_dataset_handlers(registry, services)
      register_capture_handlers(registry, services)
      register_cross_analysis_handler(registry, services)
      register_intelligence_handlers(registry, services)
      register_planning_handlers(registry, services)
      register_proposal_handlers(registry, services)
      register_extraction_handler(registry, services)
      register_orchestration_handlers(registry, services) if services.notification_store?
      registry
    end

    def register_capture_handlers(registry, services)
      registry.register("kg.captures.search") do |arguments, context|
        result = services.capture_search(context).query(
          arguments.fetch("query"), limit: arguments.fetch("limit", 25),
          include_ids: arguments.fetch("include_ids", false),
          include_restricted: context.agent.permits?("capture:restricted"),
          status: arguments["status"], kind: arguments["kind"]
        )
        HandlerResult.new(
          payload: result, why: result.fetch("explanation"),
          confidence: result.fetch("matches").empty? ? 0.0 : 1.0,
          evidence: result.fetch("matches").map do |item|
            { "record_id" => item["capture_id"] || item["title"], "role" => "capture" }
          end
        )
      rescue KnowledgeCapture::Error => error
        raise InvalidArguments, error.message
      end

      registry.register("kg.captures.propose", version: "2.0.0") do |arguments, context|
        result = services.capture_proposal_builder(context).create(arguments)
        HandlerResult.new(
          payload: result,
          why: "Recognised explicit note-like or bookmark content and produced a review-only Capture result without granting execution authority.",
          confidence: 0.98
        )
      rescue KnowledgeCapture::Error, KnowledgeExtraction::Error, ArgumentError => error
        raise InvalidArguments, error.message
      end
    end

    def register_cross_analysis_handler(registry, services)
      registry.register("kg.analysis.run", version: "1.1.0") do |arguments, context|
        result = services.cross_analysis(
          context, question: arguments.fetch("question"),
          from: arguments["from"], to: arguments["to"], as_of: arguments["as_of"],
          propose_recommendations: false
        )
        analysis = result.fetch("analysis")
        HandlerResult.new(
          payload: result,
          why: analysis.fetch("summary"), confidence: analysis.fetch("confidence"),
          evidence: analysis.fetch("graph_evidence").map do |item|
            { "record_id" => item.fetch("record_id"), "role" => "analysis_graph_evidence" }
          end,
          graph_path: analysis.fetch("graph_evidence").map { |item| item["record_id"] }.compact
        )
      rescue KnowledgeAnalysis::Error, StructuredDataset::Error => error
        raise InvalidArguments, error.message
      end
    end

    def register_dataset_handlers(registry, services)
      registry.register("kg.datasets.query") do |arguments, context|
        result = StructuredDataset::Search.new(engine: services.dataset_engine(context)).query(arguments.fetch("query"))
        raise InvalidArguments, "unsupported deterministic dataset query" unless result

        HandlerResult.new(
          payload: result,
          why: result.fetch("explanation"), confidence: result.fetch("answers").empty? ? 0.0 : 1.0,
          evidence: [{ "record_id" => result.dig("dataset", "dataset_id"), "role" => "dataset_registry" }]
        )
      rescue StructuredDataset::Error => error
        raise InvalidArguments, error.message
      end

      registry.register("kg.datasets.describe") do |arguments, context|
        description = services.dataset_engine(context).describe(arguments.fetch("dataset"))
        raise PolicyDenied, "restricted dataset requires dataset:restricted" if
          description["sensitivity"] == "restricted" && !context.agent.permits?("dataset:restricted")

        HandlerResult.new(
          payload: { "dataset" => description },
          why: "Resolved the canonical Dataset registry entry and its operational SQLite schema.",
          confidence: 1.0
        )
      rescue StructuredDataset::Error => error
        raise InvalidArguments, error.message
      end

      registry.register("kg.datasets.propose", version: "1.3.0") do |arguments, context|
        result = services.dataset_proposal_builder(context).create(arguments)
        HandlerResult.new(
          payload: result,
          warnings: result.fetch("warnings", []),
          why: "Classified structured observations and created a review-only Dataset Intent proposal without invoking graph extraction.",
          confidence: result.dig("classification", "confidence") || 0.0
        )
      rescue StructuredDataset::Error, KnowledgeExtraction::Error, ArgumentError => error
        raise InvalidArguments, error.message
      end
    end

    def register_orchestration_handlers(registry, services)
      registry.register("kg.orchestration.notify") do |arguments, context|
        notification = services.notification_store.create(
          kind: arguments.fetch("kind", "info"), title: arguments.fetch("title"),
          message: arguments.fetch("message"), trace_id: context.request.trace_id,
          correlation_id: arguments.fetch("correlation_id", context.request.trace_id),
          source: arguments.fetch("source", "agent-gateway")
        )
        HandlerResult.new(
          payload: notification.to_h,
          why: "Created an informational runtime notification; it cannot execute an action.",
          confidence: 1.0
        )
      end
    end

    def register_entity_handlers(registry, services)
      registry.register("kg.entities.search") do |arguments, context|
        limit = arguments.fetch("limit", 25)
        matches = services.graph_reader(context).search(
          arguments.fetch("query"), entity_type: arguments["entity_type"],
          strong_only: arguments.fetch("strong_only", false)
        ).first(limit).each_with_object([]) do |match, result|
          entity = services.public_entity(match.fetch(:entity), context.agent)
          result << entity.merge("signals" => match.fetch(:signals)) if entity
        end
        HandlerResult.new(
          payload: { query: arguments.fetch("query"), matches: matches },
          why: "Matched immutable IDs and normalized identity signals without exposing storage details.",
          confidence: matches.empty? ? 0.0 : 1.0
        )
      end

      registry.register("kg.entities.get") do |arguments, context|
        entity = services.graph_reader(context).find(arguments.fetch("entity_id"))
        public_entity = services.public_entity(entity, context.agent)
        raise PolicyDenied, "entity sensitivity policy denied access" unless public_entity

        HandlerResult.new(payload: { entity: public_entity })
      rescue KnowledgeGraph::EntityNotFound
        raise CapabilityNotFound, "entity not found"
      end

      registry.register("kg.projects.search") do |arguments, context|
        search_typed_records(arguments, context, services, "project", nil)
      end

      registry.register("kg.companies.search") do |arguments, context|
        search_typed_records(arguments, context, services, "organization", "company")
      end
    end

    def register_graph_handlers(registry, services)
      registry.register("kg.graph.relationship_path") do |arguments, context|
        snapshot = services.snapshot(context)
        source = snapshot.fetch(arguments.fetch("source_id"))
        target = snapshot.fetch(arguments.fetch("target_id"))
        unless services.visible_entity?(source, context.agent) && services.visible_entity?(target, context.agent)
          raise PolicyDenied, "endpoint sensitivity policy denied access"
        end
        requested_mode = arguments.fetch("mode", "auto")
        mode = if requested_mode == "auto"
                 source.type == "person" && target.type == "person" ? "social" : "knowledge"
               else
                 requested_mode
               end
        projection = mode == "social" ?
          KnowledgeIntelligence::Projection.social(snapshot, as_of: services.parse_date(arguments["as_of"])) :
          KnowledgeIntelligence::Projection.knowledge(snapshot, as_of: services.parse_date(arguments["as_of"]))
        path = KnowledgeIntelligence::GraphAlgorithms.shortest_path(projection, source.id, target.id)
        if path
          edge_record_ids = path.each_cons(2).flat_map do |first, second|
            projection.edge_ids(first, second).map { |edge_id| projection.edge_records.fetch(edge_id)["record_id"] }
          end
          visible_nodes = services.public_value(path, context)
          visible_edges = services.public_value(edge_record_ids, context)
          path = nil if visible_nodes.length != path.length || visible_edges.length != edge_record_ids.length
        end
        evidence = path ? path.each_cons(2).flat_map do |first, second|
          projection.edge_ids(first, second).map do |edge_id|
            edge = projection.edge_records[edge_id]
            { record_id: edge["record_id"], role: "path_edge" }
          end
        end : []
        HandlerResult.new(
          payload: { source_id: source.id, target_id: target.id, mode: mode, graph_path: path, distance: path && path.length - 1 },
          evidence: evidence,
          why: path ? "Computed the deterministic shortest path over the immutable graph snapshot." : "No path exists in the selected projection.",
          confidence: path ? 1.0 : 0.0, graph_path: path || []
        )
      rescue KnowledgeIntelligence::InvalidFeatureRequest
        raise CapabilityNotFound, "path endpoint not found"
      end

      registry.register("kg.graph.query") do |arguments, context|
        result = KnowledgeIntelligence::QueryEngine.new(
          snapshot: services.snapshot(context),
          feature_engine: services.feature_engine(context, as_of: arguments["as_of"]),
          as_of: services.parse_date(arguments["as_of"])
        ).query(arguments.fetch("query"))
        answers = services.public_value(result.answers, context) || []
        HandlerResult.new(
          payload: { query: result.query, kind: result.kind, answers: answers },
          why: result.explanation, confidence: 1.0,
          evidence: collect_answer_evidence(answers)
        )
      rescue KnowledgeIntelligence::InvalidQuery => error
        raise InvalidArguments, error.message
      end
    end

    def register_intelligence_handlers(registry, services)
      registry.register("kg.intelligence.analyze") do |arguments, context|
        names = arguments["analyzers"]
        run = services.analysis(context, names: names, as_of: arguments["as_of"])
        findings = services.visible_findings(run.findings, context)
        public = services.public_analysis(run, context)
        HandlerResult.new(
          payload: public,
          why: "Ran versioned deterministic analyzers against one immutable graph snapshot.",
          confidence: aggregate_confidence(findings), evidence: findings_evidence(findings, services, context),
          graph_path: findings.flat_map(&:graph_path).uniq
        )
      end

      registry.register("kg.intelligence.briefing") do |arguments, context|
        run = services.analysis(context, as_of: arguments["as_of"])
        selected = Array(arguments["entity_ids"])
        selected = context.session.selected_entity_ids if selected.empty? && context.session
        findings = services.visible_findings(run.findings, context).select do |finding|
          selected.empty? || !(finding.entity_ids & selected).empty?
        end
        findings = findings.first(arguments.fetch("limit", 50))
        entities = selected.map { |id| services.public_entity(services.snapshot(context).record(id), context.agent) }.compact
        HandlerResult.new(
          payload: {
            as_of: run.as_of, entities: entities,
            findings: findings.map { |finding| services.public_finding(finding, context) },
            summary: "#{findings.length} relevant findings for #{entities.length} selected entities."
          },
          why: "Selected findings whose immutable entity references overlap the briefing scope.",
          confidence: aggregate_confidence(findings), evidence: findings_evidence(findings, services, context),
          graph_path: findings.flat_map(&:graph_path).uniq
        )
      end

      registry.register("kg.intelligence.digest") do |arguments, context|
        period = arguments.fetch("period", "weekly")
        days = { "daily" => 1, "weekly" => 7, "monthly" => 30 }.fetch(period)
        date = services.parse_date(arguments["as_of"])
        run = services.analysis(context, as_of: date)
        report = KnowledgeIntelligence::DigestBuilder.new(snapshot: services.snapshot(context), as_of: date).build(run, days: days)
        visible_findings = services.visible_findings(run.findings, context)
        payload = services.public_report(report, context)
        HandlerResult.new(
          payload: payload, why: "Built a deterministic #{period} window from canonical facts and analyzer findings.",
          confidence: 1.0, evidence: findings_evidence(visible_findings, services, context)
        )
      end

      register_analysis_alias(registry, services, "kg.intelligence.timeline", %w[timeline], "timeline")
      register_analysis_alias(registry, services, "kg.intelligence.network", %w[network], "network")
      register_analysis_alias(registry, services, "kg.intelligence.knowledge_gaps", %w[knowledge_gap consistency], "knowledge gaps")
      register_analysis_alias(registry, services, "kg.intelligence.relationship_health", %w[relationship activity], "relationship health")
      register_analysis_alias(registry, services, "kg.intelligence.followup_status", %w[followup], "follow-up status")

      registry.register("kg.intelligence.explain_finding") do |arguments, context|
        run = services.analysis(context, as_of: arguments["as_of"])
        finding = services.visible_findings(run.findings, context).find do |item|
          item.finding_id == arguments.fetch("finding_id")
        end
        raise CapabilityNotFound, "finding not found in the current snapshot" unless finding

        HandlerResult.new(
          payload: { finding: services.public_finding(finding, context) },
          why: finding.explanation, confidence: finding.confidence,
          evidence: finding.evidence.map { |item| services.public_evidence(item, context) }.compact,
          graph_path: finding.graph_path
        )
      end
    end

    def register_proposal_handlers(registry, services)
      registry.register("kg.proposals.create") do |arguments, context|
        run = services.analysis(context, names: ["recommendation"], as_of: arguments["as_of"])
        visible = services.visible_findings(run.findings, context).select { |finding| !finding.intent_proposals.empty? }
        requested = Array(arguments["finding_ids"])
        if !requested.empty? && (requested - visible.map(&:finding_id)).any?
          raise CapabilityNotFound, "requested finding is unavailable under current policy"
        end
        selected_ids = requested.empty? ? visible.map(&:finding_id) : requested
        raise InvalidArguments, "no policy-visible Intent proposals are available" if selected_ids.empty?
        payload = KnowledgeIntelligence::ProposalAdapter.new.build(
          run, finding_ids: selected_ids
        )
        path = KnowledgeIntelligence::ProposalAdapter.new.persist(payload, vault_root: services.vault_root)
        raise ExecutionFailed, "proposal persistence failed" unless path

        HandlerResult.new(
          payload: {
            proposal_id: payload.fetch("proposal_id"), status: payload.fetch("status"),
            planned_intent_count: payload.fetch("planned_intents").length, executable: false
          },
          why: "Converted deterministic findings into an immutable review-only proposal; no Intent was executed.",
          confidence: 1.0
        )
      rescue KnowledgeIntelligence::Error => error
        raise InvalidArguments, error.message
      end

      registry.register("kg.proposals.validate") do |arguments, context|
        proposal_id = arguments.fetch("proposal_id")
        proposal = services.proposal_store(context).load(proposal_id)
        KnowledgeExtraction::ProposalValidator.new.validate!(proposal)
        HandlerResult.new(payload: { proposal_id: proposal_id, status: "valid" })
      rescue KnowledgeExtraction::ProposalNotFound
        raise ProposalNotFound, "proposal not found"
      rescue KnowledgeExtraction::PlanningFailure => error
        raise InvalidArguments, error.message
      end

      registry.register("kg.proposals.status") do |arguments, context|
        proposal_id = arguments.fetch("proposal_id")
        store = services.proposal_store(context)
        proposal = store.load(proposal_id)
        approval = store.approval(proposal_id)
        HandlerResult.new(payload: {
          proposal_id: proposal_id, status: proposal.fetch("status"),
          immutable_fingerprint: store.proposal_fingerprint(proposal),
          approval_status: approval ? "approved" : "not_approved",
          approved_intent_ids: approval ? approval.fetch("approved_intent_ids") : []
        })
      rescue KnowledgeExtraction::ProposalNotFound
        raise ProposalNotFound, "proposal not found"
      end

      registry.register("kg.proposals.submit") do |arguments, context|
        proposal_id = arguments.fetch("proposal_id")
        result = KnowledgeExtraction::ProposalSubmitter.new(
          engine: services.engine(context), store: services.proposal_store(context),
          dataset_engine: services.dataset_engine(context)
        ).submit(proposal_id, dry_run: arguments.fetch("dry_run", false))
        HandlerResult.new(
          payload: SecurityGuard.sanitize(result),
          why: "Submitted only the exact immutable proposal covered by the existing approval receipt.",
          confidence: result.fetch("status") == "executed" ? 1.0 : 0.5
        )
      rescue KnowledgeExtraction::ProposalNotFound
        raise ProposalNotFound, "proposal not found"
      rescue KnowledgeExtraction::ApprovalSubmissionFailure => error
        raise ApprovalRequired, error.message
      end
    end

    def register_planning_handlers(registry, services)
      registry.register("kg.planning.plan") do |arguments, context|
        result = planning_decision(arguments, context, services)
        public = services.public_planning_result(result, context)
        approved = result.approved_plan
        visible_approved = approved && services.visible_plan?(approved, context)
        HandlerResult.new(
          payload: public,
          why: visible_approved ? approved.explanation : "No policy-visible plan passed every hard constraint.",
          confidence: visible_approved ? approved.scenario.confidence : 0.0,
          evidence: visible_approved ? approved.plan.evidence.map { |item| services.public_evidence(item, context) }.compact : [],
          graph_path: visible_approved ? services.public_value(approved.plan.metadata["graph_path"], context) || [] : []
        )
      rescue KnowledgePlanning::Error => error
        raise InvalidArguments, error.message
      end

      registry.register("kg.planning.compare") do |arguments, context|
        result = planning_decision(arguments, context, services)
        public = services.public_planning_result(result, context)
        alternatives = public.fetch("ranked_plans").map do |item|
          scenario = item.fetch("scenario")
          plan = scenario.fetch("plan")
          {
            "rank" => item.fetch("rank"), "plan_id" => plan.fetch("plan_id"),
            "title" => plan.fetch("title"), "planner_id" => plan.fetch("planner_id"),
            "status" => item.fetch("decision_status"), "utility_score" => item.fetch("utility_score"),
            "pareto_optimal" => item.fetch("pareto_optimal"),
            "constraints_satisfied" => scenario.fetch("constraints_satisfied"),
            "why" => item.fetch("explanation")
          }
        end
        approved = public["approved_plan"]
        HandlerResult.new(
          payload: {
            decision_id: public.fetch("decision_id"),
            approved_plan_id: approved && approved.dig("scenario", "plan", "plan_id"),
            alternatives: alternatives, executable: false
          },
          why: approved ? approved.fetch("explanation") : "No policy-visible plan passed every hard constraint.",
          confidence: approved ? approved.dig("scenario", "confidence") : 0.0
        )
      rescue KnowledgePlanning::Error => error
        raise InvalidArguments, error.message
      end

      registry.register("kg.planning.simulate") do |arguments, context|
        result = planning_decision(arguments, context, services)
        public = services.public_planning_result(result, context)
        selected = select_public_plan(public, arguments["plan_id"])
        scenario = selected.fetch("scenario")
        HandlerResult.new(
          payload: {
            decision_id: public.fetch("decision_id"),
            plan_id: scenario.dig("plan", "plan_id"), simulation: scenario.fetch("simulation"),
            constraints_satisfied: scenario.fetch("constraints_satisfied"),
            violations: scenario.fetch("constraint_violations"), executable: false
          },
          why: "Simulated only deterministic counts, duration, cost, and declared plan requirements.",
          confidence: scenario.fetch("confidence")
        )
      rescue KnowledgePlanning::Error => error
        raise InvalidArguments, error.message
      end

      registry.register("kg.planning.explain") do |arguments, context|
        result = planning_decision(arguments, context, services)
        public = services.public_planning_result(result, context)
        selected = select_public_plan(public, arguments["plan_id"])
        scenario = selected.fetch("scenario")
        HandlerResult.new(
          payload: {
            decision_id: public.fetch("decision_id"), plan_id: scenario.dig("plan", "plan_id"),
            selected: selected.fetch("decision_status") == "decision_approved",
            why: selected.fetch("explanation"), score_trace: selected.fetch("score_trace"),
            constraint_violations: scenario.fetch("constraint_violations"), executable: false
          },
          why: selected.fetch("explanation"), confidence: scenario.fetch("confidence")
        )
      rescue KnowledgePlanning::Error => error
        raise InvalidArguments, error.message
      end

      registry.register("kg.planning.create_proposal") do |arguments, context|
        result = planning_decision(arguments, context, services)
        approved = result.approved_plan
        unless approved && services.visible_plan?(approved, context)
          raise PolicyDenied, "decision-approved plan is unavailable under current sensitivity policy"
        end
        payload = KnowledgePlanning::ProposalAdapter.new.build(result)
        path = KnowledgePlanning::ProposalAdapter.new.persist(payload, vault_root: services.vault_root)
        raise ExecutionFailed, "planning proposal persistence failed" unless path

        HandlerResult.new(
          payload: {
            proposal_id: payload.fetch("proposal_id"), status: payload.fetch("status"),
            decision_id: result.decision_id,
            planned_intent_count: payload.fetch("planned_intents").length, executable: false
          },
          why: "Persisted only reviewable Intents from the decision-approved plan; nothing was executed.",
          confidence: approved.scenario.confidence
        )
      rescue KnowledgePlanning::Error => error
        raise InvalidArguments, error.message
      end
    end

    def register_extraction_handler(registry, services)
      registry.register("kg.extraction.extract_source", version: "1.1.0") do |arguments, context|
        envelope_metadata = {
          "observation_id" => arguments["observation_id"],
          "observation_source" => arguments["origin_source"],
          "conversation_id" => arguments["conversation_id"],
          "message_id" => arguments["message_id"],
          "sender" => arguments["sender"]
        }.reject { |_key, value| value.nil? }
        metadata = {
          language: arguments.fetch("language", "und"), captured_at: arguments["captured_at"],
          external_id: arguments["external_id"], source_uri: arguments["source_uri"],
          title: arguments["title"], author: arguments["sender"],
          metadata: envelope_metadata.merge("sensitivity" => arguments.fetch("sensitivity", "private"))
        }.reject { |_key, value| value.nil? }
        proposal = services.extraction_pipeline(context).process(
          arguments.fetch("content"), source_type: arguments.fetch("source_type"),
          persist: true, **metadata
        )
        HandlerResult.new(
          payload: {
            proposal_id: proposal.proposal_id, status: proposal.status,
            fact_count: proposal.facts.length, planned_intent_count: proposal.planned_intents.length,
            executable: false
          },
          warnings: proposal.warnings,
          why: "Normalized untrusted source text, retained exact evidence, and created a review-only proposal.",
          confidence: proposal.facts.empty? ? 0.0 : 1.0
        )
      rescue KnowledgeExtraction::Error => error
        raise InvalidArguments, error.message
      end
    end

    def register_analysis_alias(registry, services, capability_id, names, label)
      registry.register(capability_id) do |arguments, context|
        run = services.analysis(context, names: names, as_of: arguments["as_of"])
        findings = services.visible_findings(run.findings, context)
        if arguments["entity_id"]
          findings = findings.select { |finding| finding.entity_ids.include?(arguments["entity_id"]) }
        end
        HandlerResult.new(
          payload: {
            as_of: run.as_of, analyzers: run.results.map(&:analyzer),
            findings: findings.map { |finding| services.public_finding(finding, context) },
            metrics: run.results.each_with_object({}) do |result, value|
              value[result.analyzer] = services.public_value(result.metrics, context) || {}
            end
          },
          why: "Computed deterministic #{label} findings from an immutable graph snapshot.",
          confidence: aggregate_confidence(findings), evidence: findings_evidence(findings, services, context),
          graph_path: findings.flat_map(&:graph_path).uniq
        )
      end
    end

    def search_typed_records(arguments, context, services, type, org_kind)
      normalized = arguments.fetch("query").downcase.strip
      matches = services.snapshot(context).records(type: type).select do |record|
        next false if org_kind && record["org_kind"] != org_kind
        next false unless services.visible_entity?(record, context.agent)

        ([record.name] + Array(record["aliases"])).compact.any? { |name| name.to_s.downcase.include?(normalized) }
      end.sort_by { |record| [record.name.to_s, record.id] }.first(arguments.fetch("limit", 25))
      HandlerResult.new(
        payload: { query: arguments.fetch("query"), matches: matches.map { |record| services.public_entity(record, context.agent) } },
        why: "Matched canonical names and aliases within the requested entity type.",
        confidence: matches.empty? ? 0.0 : 1.0
      )
    end

    def planning_decision(arguments, context, services)
      values = arguments.fetch("goal").transform_keys(&:to_s)
      goal = KnowledgePlanning::Goal.new(
        id: values["id"] || KnowledgePlanning::Stable.id("goal", values),
        description: values.fetch("description"),
        goal_type: values.fetch("goal_type", "generic"),
        priority: values.fetch("priority", "normal"), deadline: values["deadline"],
        constraints: values.fetch("constraints", {}), preferences: values.fetch("preferences", {}),
        success_criteria: values.fetch("success_criteria", []), status: values.fetch("status", "active")
      )
      services.planning(context, goal: goal, as_of: arguments["as_of"])
    rescue KeyError => error
      raise InvalidArguments, "missing goal field #{error.key}"
    end

    def select_public_plan(public, plan_id)
      ranked = public.fetch("ranked_plans")
      selected = if plan_id.to_s.empty?
                   ranked.find { |item| item.fetch("decision_status") == "decision_approved" } || ranked.first
                 else
                   ranked.find { |item| item.dig("scenario", "plan", "plan_id") == plan_id }
                 end
      raise CapabilityNotFound, "plan not found under current policy" unless selected

      selected
    end

    def findings_evidence(findings, services, context)
      findings.flat_map(&:evidence).uniq(&:evidence_id).map do |item|
        services.public_evidence(item, context)
      end.compact
    end

    def aggregate_confidence(findings)
      return 1.0 if findings.empty?

      findings.sum(&:confidence) / findings.length.to_f
    end

    def collect_answer_evidence(answers)
      Array(answers).flat_map { |answer| Array(answer["evidence"] || answer[:evidence]) }.map do |item|
        SecurityGuard.sanitize(item)
      end
    end
  end
end
