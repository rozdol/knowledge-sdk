# frozen_string_literal: true

module KnowledgeFinance
  module EntityPolicy
    def create(intent, context)
      Catalog.new(vault_root: @vault_root).validate_record!(intent.entity_type, intent.attributes.transform_keys(&:to_s))
      super
    rescue InvalidFinance => error
      raise KnowledgeGraph::InvalidIntent, error.message
    end

    def update(intent, context)
      record = repository.resolve(intent.entity_id)
      Catalog.new(vault_root: @vault_root).validate_record!(record.type, record.data.merge(intent.changes.transform_keys(&:to_s)), previous: record.data)
      super
    rescue InvalidFinance => error
      raise KnowledgeGraph::InvalidIntent, error.message
    end
  end

  module IdentityPolicy
    def merge(intent, context)
      records = [repository.resolve(intent.primary_id), repository.resolve(intent.secondary_id)]
      raise KnowledgeGraph::ApprovalRequired, "financial identities cannot be merged; reconcile exact identifiers explicitly" if records.any? { |r| r.type.start_with?("financial_") }
      super
    end
  end

  # These immutable adapters bind finance analysis to the SAME snapshot and
  # Dataset signature as the existing Analysis Engine's cache key.
  class SnapshotCatalog < Catalog
    def initialize(snapshot)
      @snapshot = snapshot
    end

    def records(type)
      @snapshot.records(type: type)
    end

    def snapshot
      self
    end

    def resolve(id, type = nil)
      record = @snapshot.record(id)
      raise InvalidFinance, "financial reference is absent from analysis snapshot" unless record && (!type || record.type == type)
      raise InvalidFinance, "merged financial references require explicit reconciliation" if record.data["record_status"] == "merged"
      record
    end
  end

  class AnalysisRows
    def initialize(context)
      @context = context
    end

    def query(dataset, limit:, offset:, **_options)
      data = @context.dataset(dataset)
      return [] unless data
      rows = data.fetch("rows")
      if data.dig("statistics", "row_count").to_i > rows.length
        raise InvalidFinance, "analysis snapshot truncates financial history; use a complete finance report"
      end
      rows.sort_by { |r| r["row_id"] }[offset, limit] || []
    end
  end

  module FinanceAnalysis
    def supports?(question, context)
      classified = Classifier.parse(question)
      return true if context.dataset("finance_events") && classified &&
        %w[finance.query_holdings finance.query_debts finance.query_performance finance.analyze_portfolio].include?(classified["intent"])
      super
    end

    def contributions
      super.merge("dataset_interpreters" => %w[expenses subscriptions income finance_events finance_observations],
                  "analyzers" => %w[finance fifo_performance net_worth])
    end

    def analyze(context)
      classification = Classifier.parse(context.question)
      return super unless context.dataset("finance_events") && classification && classification["intent"].start_with?("finance.")
      service = Service.new(vault_root: "/", dataset_engine: AnalysisRows.new(context), catalog: SnapshotCatalog.new(context.snapshot),
                            clock: -> { Time.utc(context.as_of.year, context.as_of.month, context.as_of.day, 23, 59, 59) })
      owner = service.owner_scope
      window = Window.new(context.question, context.as_of)
      from = context.from ? context.from.iso8601 : window.from
      to = (context.from || context.window_explicit) && context.to ? context.to.iso8601 : window.to
      assets = service.matching_assets(context.question)
      scope = assets.length == 1 ? assets.first.id : nil
      report = if !owner then service.scope_clarification
               elsif context.question.match?(/опционах\s+[A-Z][A-Z0-9._-]*\b/i) && (assets.empty? || assets.any? { |a| a.data["asset_class"] == "future" })
                 { "status" => "clarification_required", "execution_authorized" => false, "question" => "Select the exact option contract or linked contract group." }
               elsif assets.length > 1 then { "status" => "clarification_required", "execution_authorized" => false,
                 "question" => "Choose the exact instrument identity.", "candidates" => assets.map { |a| { "asset_id" => a.id, "name" => a.data["name"] } } }
               elsif classification["intent"] == "finance.analyze_portfolio" then service.networth(owner_id: owner, as_of: to)
               elsif classification["intent"] == "finance.query_debts" then service.debt_report(owner_id: owner, as_of: to)
               elsif classification["intent"] == "finance.query_holdings" then scope ? service.holdings(owner_id: owner, asset_id: scope, as_of: to) :
                 { "status" => "clarification_required", "question" => "Choose an instrument identity.", "execution_authorized" => false }
               elsif context.question.match?(/monthly|по\s+месяц/i) then service.monthly(owner_id: owner, from: from, to: to, asset_id: scope)
               elsif context.question.match?(/доходност|\breturns?\b|performance/i) && !context.question.match?(/p&l|прибыл|profit/i)
                 scope ? { "status" => "unavailable", "execution_authorized" => false, "limitations" => ["Instrument percentage returns need attributed cash flows."] } :
                   service.performance(owner_id: owner, from: from, to: to)
               else service.pnl(owner_id: owner, from: from, to: to, asset_id: scope)
               end
      fragment(
        summary: "Financial ledger report (#{report['status']}), explicit owner scope and FIFO accounting.",
        confidence: report["status"] == "ok" ? 1.0 : 0.0,
        limitations: report.fetch("limitations", []),
        activity_evidence: context.relevant_activities(%w[finance_events finance_observations], limit: 20)
      ).merge("domain_reports" => [{ "domain" => "finance", "report" => report }])
    rescue InvalidFinance => error
      fragment(summary: "Financial history cannot support a complete report.", confidence: 0.0, limitations: [error.message])
    end
  end

  module HandlerExtension
    def build(services)
      registry = super
      Plugin.register_handlers(registry, services)
      registry
    end
  end

  module ActivityExtension
    def dataset_summary(audit, privacy)
      if privacy != "redacted" && audit["dataset_name"] == "Financial Ledger" && audit["dataset_action"] == "import"
        return "Financial ledger recorded immutable economic events; positions and balances are reproducible from this history."
      end
      super
    end
  end

  module SearchExtension
    def query(text)
      classification = Classifier.parse(text)
      if classification && classification["intent"].start_with?("finance.query_", "finance.analyze_")
        raise AgentPlatform::PolicyDenied, "financial queries require finance:read" if @authorizer && !@authorizer.call("finance:read")
        root = @engine.instance_variable_get(:@vault_root)
        result = Conversation.new(vault_root: root, dataset_engine: @engine, clock: @clock).read("content" => text)
        metadata = @engine.describe("finance_events").slice("dataset_id", "slug", "purpose", "graph_path")
        return { "query" => text, "kind" => "finance_query", "answers" => [result], "dataset" => metadata,
                 "explanation" => "Read policy-visible financial history in this Vault." }
      end
      super
    rescue StructuredDataset::DatasetNotFound
      nil
    end
  end

  module Plugin
    INTENTS = %w[record_transaction open_position close_position register_asset register_liability record_repayment
                 register_owner register_account query_holdings query_debts query_performance analyze_portfolio plan_liquidity].freeze
    module_function

    def register
      KnowledgeGraph::EntityManager.prepend(EntityPolicy)
      KnowledgeGraph::IdentityManager.prepend(IdentityPolicy)
      StructuredDataset::Engine.prepend(DatasetPolicy)
      StructuredDataset::Search.prepend(SearchExtension)
      KnowledgeAnalysis::Plugins::Finance.prepend(FinanceAnalysis)
      KnowledgePlanning::ScenarioEvaluator.prepend(LiquidityConstraints)
      KnowledgeActivity::Timeline.prepend(ActivityExtension)
      AgentPlatform::DefaultHandlers.singleton_class.prepend(HandlerExtension)
      StructuredDataset.routing_registry.register(
        intent: "dataset.finance_rows", dataset: "finance_events", intent_class: KnowledgeGraph::AppendFinanceRows,
        builder: ->(common, slots) { KnowledgeGraph::AppendFinanceRows.new(**common.merge(slots)) },
        writer: ->(engine, intent, provenance) { engine.append_finance(intent.dataset, intent.rows, provenance) },
        row_builder: ->(intent) { intent.rows.first || {} }
      )
      %w[finance trading generic].each do |domain|
        %w[dataset search].each do |route|
          KnowledgeSDK.intent_classifier.register(name: "finance-wealth-#{domain}-#{route}", domain: domain, route: route) do |text, context|
            result = Classifier.parse(text, context)
            result if result && result["route"] == route
          end
        end
      end
      INTENTS.each do |name|
        read = name.start_with?("query_", "analyze_", "plan_")
        KnowledgeGraph::ChatIntentResolver.register_intent_capability(
          intent: "finance.#{name}", capability: read ? "kg.finance.read" : "kg.finance.propose",
          permissions: %w[finance:read finance:create]
        )
      end
      KnowledgeSDK::ConversationExtensions.register("finance") do |root, args, actor|
        pending = ConversationState.new(root).load(args.merge("_finance_actor" => actor))
        pending && pending["status"] == "clarification_required" ? args.merge("finance_pending" => true) : args
      rescue InvalidFinance
        args
      end
      register_templates
    end

    def register_templates
      [Schemas.events, Schemas.observations].each do |definition|
        template = StructuredDataset::DatasetTemplate.new(
          id: definition.slug, version: "1.0.0", domain: "finance", definition: definition,
          parser: StructuredDataset::TemplateParsers::Delimited.new, plugin: "finance",
          keywords: [], matcher: ->(_observation, _template) { nil },
          privacy_level: "private", validation_rules: %w[exact_decimal_strings append_only exact_approval],
          recommended_analyzers: %w[finance], recommendation_rules: ["review_only"],
          analysis_semantics: { "accounting_basis" => "fifo", "canonical_quantities" => "event_replay" }
        )
        StructuredDataset.template_registry.register(template)
      end
    end

    def register_handlers(registry, services)
      %w[read propose].each do |action|
        registry.register("kg.finance.#{action}") do |arguments, context|
          restricted = %w[finance:restricted graph:restricted dataset:restricted].all? { |permission| context.agent.permits?(permission) }
          reader = Service.new(vault_root: services.vault_root, dataset_engine: services.dataset_engine(context), include_restricted: restricted, clock: services.clock)
          # Structured requests cannot downgrade restricted referenced identities.
          arguments.fetch("content").scan(/(?:person|organization|financialowner|financialaccount|financialasset)_[0-9A-HJKMNP-TV-Z]{26}/).each do |id|
            raise AgentPlatform::PolicyDenied, "restricted financial reference" unless reader.visible?("asset_id" => id)
          end
          conversation = Conversation.new(vault_root: services.vault_root, dataset_engine: services.dataset_engine(context),
                                           proposal_store: services.proposal_store(context), include_restricted: restricted,
                                           clock: services.clock, event_bus: services.event_bus)
          payload = conversation.public_send(action, arguments.merge("_finance_actor" => context.agent.id))
          AgentPlatform::HandlerResult.new(payload: payload, why: "Finance uses exact approved Intents and deterministic ledger replay; this call cannot execute trades.", confidence: 1.0)
        rescue KnowledgeFinance::Error, StructuredDataset::Error, KnowledgeExtraction::Error, ArgumentError => error
          raise AgentPlatform::InvalidArguments, error.message
        end
      end
    end
  end
end
