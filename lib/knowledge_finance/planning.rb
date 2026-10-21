# frozen_string_literal: true

module KnowledgeFinance
  module LiquidityConstraints
    def evaluate(goal, candidates, context)
      scenarios = super
      return scenarios unless goal.goal_type == "finance_liquidity"
      scenarios.map do |scenario|
        next scenario if scenario.plan.metadata["target_met"]
        KnowledgePlanning::ScenarioEvaluation.new(
          plan: scenario.plan, simulation: scenario.simulation, criteria: scenario.criteria,
          feature_trace: scenario.feature_trace, benefits: scenario.benefits, risks: scenario.risks,
          cost: scenario.cost, expected_outcome: scenario.expected_outcome, confidence: scenario.confidence,
          violations: scenario.violations + [{ "constraint" => "net_cash_target", "expected" => goal.preferences["target"],
            "actual" => scenario.plan.metadata["estimated_net_cash"], "message" => "Modeled net cash does not reach the target" }]
        )
      end.freeze
    end
  end

  # Candidate generation plugs into the existing Planning Engine. All cash math
  # stays decimal; the shared Decision Engine handles only dimensionless scores.
  class LiquidityCandidates < KnowledgePlanning::Planner
    def initialize(candidates:, target:, currency:)
      @candidates = candidates
      @target = target
      @currency = currency
      super(planner_id: "finance_liquidity", goal_types: ["finance_liquidity"])
    end

    def plan(goal, _graph, _constraints, context:)
      ["Minimize estimated costs", "Fastest modeled liquidity"].map do |strategy|
        sources = @candidates.sort_by do |candidate|
          primary = strategy.start_with?("Minimize") ? candidate.fetch("cost_rate") : candidate.fetch("settlement_days")
          [primary, candidate.fetch("account_id"), candidate["asset_id"].to_s]
        end
        remaining = @target
        actions = []
        sources.each do |source|
          break if remaining <= 0
          net = [source.fetch("net"), remaining].min
          # Cash may be used partially; securities use supported unit increments.
          if source["kind"] == "sale"
            quantity = (net / source.fetch("net_per_unit") / source.fetch("unit_step")).ceil * source.fetch("unit_step")
            quantity = [quantity, source.fetch("quantity")].min
            net = quantity * source.fetch("net_per_unit")
            actions << source.fetch("public").merge("quantity" => Decimal.text(quantity), "estimated_net_cash" => Decimal.text(net))
          else
            actions << source.fetch("public").merge("estimated_net_cash" => Decimal.text(net))
          end
          remaining -= net
        end
        total = actions.sum { |action| Decimal.value(action["estimated_net_cash"]) }
        days = actions.map { |a| a["settlement_days"] }.max || 0
        steps = actions.each_with_index.map do |action, index|
          KnowledgePlanning::PlanStep.new(
            seed: [goal.id, strategy, index], action: "review_liquidity_source",
            description: "Review #{action['kind']} from #{action['account_id']}",
            entity_ids: [action["account_id"], action["asset_id"]].compact,
            estimated_duration_days: action["settlement_days"], required_approval: "human_review"
          )
        end
        steps = [KnowledgePlanning::PlanStep.new(seed: goal.id, action: "clarify_liquidity", description: "Obtain missing liquidity inputs", required_approval: "human_review")] if steps.empty?
        KnowledgePlanning::CandidatePlan.new(
          goal_id: goal.id, planner_id: planner_id, planner_version: version, title: strategy,
          steps: steps, estimated_effort: actions.length, estimated_value: total >= @target ? 1 : 0,
          confidence: actions.empty? ? 0 : 0.7, evidence: [], risk: "medium",
          metadata: {
            "actions" => actions, "estimated_net_cash" => Decimal.text(total), "currency" => @currency,
            "target_met" => total >= @target, "expected_duration_days" => days,
            "preference_alignment" => strategy.start_with?("Minimize") ? 0.8 : 0.7,
            "benefits" => ["Conditional review only; no executable orders"],
            "entity_ids" => actions.flat_map { |a| [a["account_id"], a["asset_id"]] }.compact,
            "assumptions" => ["Supplied costs and settlement calendar-day estimates hold; market access remains subject to human verification."],
            "risks" => ["Quotes can change; cash is not guaranteed withdrawable; concentration and margin require review."]
          }
        )
      end
    end
  end

  class Service
    def liquidity(owner_id: nil, target:, currency: @reporting_currency, deadline: nil, as_of: nil, constraints: {})
      owner = owner_scope(owner_id)
      return scope_clarification unless owner
      raise InvalidFinance, "unsupported liquidity constraint" unless (constraints.keys - %w[exclude_assets minimum_holdings]).empty?
      goal_amount = Decimal.positive!(target)
      at = timestamp(as_of)
      candidates, missing = liquidity_sources(owner, at, currency, constraints)
      goal = KnowledgePlanning::Goal.new(
        id: KnowledgePlanning::Stable.id("goal", "finance_liquidity", owner, target, currency, at, constraints),
        description: "Model net cash of #{target} #{currency}", goal_type: "finance_liquidity", deadline: deadline,
        constraints: deadline ? { "max_duration_days" => [(Date.iso8601(deadline) - Date.iso8601(at[0, 10])).to_i, 0].max } : {},
        preferences: { "currency" => currency, "target" => target }
      )
      result = KnowledgePlanning::Engine.new(
        snapshot: KnowledgeIntelligence::GraphSnapshot.load(vault_root: catalog.root), as_of: Date.iso8601(at[0, 10]),
        planners: [LiquidityCandidates.new(candidates: candidates, target: goal_amount, currency: currency)]
      ).plan(goal)
      scenarios = result.ranked_plans.map do |ranked|
        meta = ranked.plan.metadata
        { "name" => ranked.plan.title, "estimated_net_cash" => meta["estimated_net_cash"],
          "target_met" => meta["target_met"], "estimated_settlement" => nil,
          "estimated_settlement_days" => meta["expected_duration_days"], "actions" => meta["actions"],
          "assumptions" => meta["assumptions"], "risks" => meta["risks"],
          "constraint_violations" => ranked.scenario.violations, "decision_status" => ranked.decision_status }
      end
      { "status" => "conditional_scenario", "owner_id" => owner, "as_of" => at,
        "target" => { "amount" => Decimal.text(goal_amount), "currency" => currency, "deadline" => deadline },
        "scenarios" => scenarios, "missing_inputs" => missing,
        "planning_policy" => result.policy_version, "decision_trace" => result.to_h[:decision_trace],
        "execution_authorized" => false, "executable" => false }
    end

    def liquidity_sources(owner, at, currency, constraints)
      candidates = []
      missing = []
      book = projection(owner_id: owner, as_of: at)
      derivative_accounts = book.positions.select do |position|
        %w[future option futures_option].include?(catalog.asset(position["asset_id"]).data["asset_class"])
      end.map { |position| position["account_id"] }.uniq
      accounts = catalog.records("financial_account").select { |a| Array(a.data["owner_ids"]).include?(owner) }
      by_account = accounts.to_h { |a| [a.id, catalog.details(a).fetch("liquidity", {})] }
      entries = book.cash.keys.select { |k| k[0] == owner && book.cash[k] > 0 }.map do |key|
        { "kind" => "cash", "account_id" => key[1], "currency" => key[2], "amount" => book.cash[key] }
      end
      book.positions.each do |position|
        next if Decimal.value(position["quantity"]) <= 0
        entries << position.merge("kind" => "sale")
      end
      entries.each do |item|
        next if Array(constraints["exclude_assets"]).include?(item["asset_id"])
        settings = by_account.fetch(item["account_id"], {})
        absent = %w[accessible permissions_confirmed settlement_days commission_rate fx_cost_rate].reject { |field| settings.key?(field) }
        absent << "portfolio_margin_and_hedge_review" if derivative_accounts.include?(item["account_id"]) && settings["margin_review_confirmed"] != true
        if settings["accessible"] == false || settings["permissions_confirmed"] == false || settings["collateral_restricted"] == true
          missing << item.slice("account_id", "asset_id").merge("reason" => "restricted account or collateral")
          next
        end
        if item["kind"] == "sale"
          instrument = catalog.asset(item["asset_id"])
          if catalog.details(instrument)["pledged_as_collateral"] == true
            missing << item.slice("account_id", "asset_id").merge("reason" => "asset is pledged as collateral")
            next
          end
          unless %w[stock etf mutual_fund bond].include?(instrument.data["asset_class"])
            missing << item.slice("account_id", "asset_id").merge("reason" => "derivative margin/strategy or illiquid liquidation model unavailable")
            next
          end
          price = observation("price", owner: owner, at: at, asset_id: instrument.id, currency: item["currency"])
          last_split = book.active_events.select do |event|
            event["asset_id"] == instrument.id && event["account_id"] == item["account_id"] && event["operation"] == "SPLIT"
          end.map { |event| event["effective_at"] }.max
          price = nil if price && last_split && price["as_of"] < last_split
          unless price && price["price_type"] == "bid" && price["quality"] == "verified" && Time.iso8601(at) - Time.iso8601(price["as_of"]) <= 900
            absent << "current_verified_executable_bid"
          end
          absent << "unit_step" unless settings["unit_step"]
        else
          absent << "withdrawable_cash_confirmed" unless settings["withdrawable_cash_confirmed"] == true
        end
        if absent.any?
          missing << item.slice("account_id", "asset_id").merge("fields" => absent)
          next
        end
        commission = Decimal.value(settings["commission_rate"])
        fx_cost = item["currency"] == currency ? BigDecimal("0") : Decimal.value(settings["fx_cost_rate"])
        tax = Decimal.value(settings.fetch("tax_rate", "0"))
        cost = commission + fx_cost + tax
        raise InvalidFinance, "liquidity cost rates must be nonnegative and total less than one" if [commission, fx_cost, tax].any? { |n| n < 0 } || cost >= 1
        days = Integer(settings["settlement_days"])
        raise InvalidFinance, "settlement days cannot be negative" if days < 0
        if item["kind"] == "cash"
          native = item["amount"]
        else
          minimum = Decimal.value(constraints.fetch("minimum_holdings", {}).fetch(item["asset_id"], "0"))
        raise InvalidFinance, "minimum holdings cannot be negative" if minimum < 0
        qty = [Decimal.value(item["quantity"]) - minimum, BigDecimal("0")].max
          step = Decimal.positive!(settings["unit_step"])
          qty = (qty / step).floor * step
          next if qty.zero?
          native = qty * Decimal.value(price["value"]) * Decimal.value(instrument.data["multiplier"])
        end
        converted, fx = convert(native, from: item["currency"], to: currency, owner: owner, at: at)
        if converted.nil? || (item["currency"] != currency && fx["freshness"] != "fresh")
          missing << item.slice("account_id", "asset_id").merge("fields" => ["fresh_fx_rate"])
          next
        end
        net = converted * (1 - cost)
        next unless net > 0
        candidates << {
          "kind" => item["kind"], "net" => net, "cost_rate" => cost, "settlement_days" => days,
          "quantity" => qty, "unit_step" => step, "net_per_unit" => qty && net / qty,
          "account_id" => item["account_id"], "asset_id" => item["asset_id"],
          "public" => item.slice("kind", "account_id", "asset_id").merge(
            "currency" => currency, "settlement_days" => days, "cost_rate" => Decimal.text(cost),
            "fx" => fx, "quote" => price && price.slice("as_of", "value", "source"), "executable" => false
          )
        }
      end
      [candidates, missing]
    end
  end
end
