# frozen_string_literal: true

module KnowledgeFinance
  class Service
    attr_reader :catalog, :engine, :clock

    def initialize(vault_root:, dataset_engine: nil, clock: nil, include_restricted: false, reporting_currency: "EUR", catalog: nil)
      @catalog = catalog || Catalog.new(vault_root: vault_root)
      @clock = clock || -> { Time.now }
      @engine = dataset_engine || StructuredDataset::Engine.new(vault_root: vault_root, clock: @clock)
      @include_restricted = include_restricted
      @reporting_currency = reporting_currency
    end

    def matching_assets(text, fields = {})
      return [catalog.asset(fields["asset_id"])] if fields["asset_id"] && visible?("asset_id" => fields["asset_id"])
      catalog.records("financial_asset").select do |asset|
        next false unless visible?("asset_id" => asset.id)
        names = [asset.data["name"], *Array(asset.data["aliases"])]
        names.any? { |name| !name.to_s.empty? && text.match?(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i) } ||
          JSON.parse(asset.data.fetch("identifiers_json", "[]")).any? do |id|
            %w[isin conid].include?(id["type"]) && text.include?(id["value"])
          end
      end
    end

    def timestamp(value = nil, end_of_day: true)
      text = (value || clock.call.iso8601).to_s
      text = "#{text}T#{end_of_day ? '23:59:59.999999' : '00:00:00'}Z" if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      Time.iso8601(text).utc.iso8601(6)
    rescue ArgumentError
      raise InvalidFinance, "date must be ISO 8601"
    end

    def visible?(row)
      return true if @include_restricted
      return false if row["sensitivity"] == "restricted"
      %w[owner_id account_id asset_id].all? do |key|
        !row[key] || catalog.resolve(row[key]).data["sensitivity"] != "restricted"
      end
    rescue InvalidFinance
      false
    end

    def restricted_reads?
      @include_restricted
    end

    def rows(dataset)
      result = []
      offset = 0
      loop do
        page = engine.query(dataset, order: "row_id:asc", limit: 10_000, offset: offset)
        result.concat(page.select { |row| visible?(row) })
        break if page.length < 10_000
        offset += 10_000
        raise InvalidFinance, "finance replay exceeds 100000 rows; partition import history before querying" if offset >= 100_000
      end
      result
    rescue StructuredDataset::DatasetNotFound
      []
    end

    def owner_scope(owner_id = nil)
      if owner_id
        record = catalog.owner!(owner_id)
        raise InvalidFinance, "owner is not visible under this policy" unless @include_restricted || record.data["sensitivity"] != "restricted"
        return owner_id
      end
      owners = catalog.records("financial_account").flat_map { |r| Array(r.data["owner_ids"]) }.uniq.select do |id|
        @include_restricted || catalog.owner!(id).data["sensitivity"] != "restricted"
      end
      owners.length == 1 ? owners.first : nil
    end

    def scope_clarification
      { "status" => "clarification_required", "missing_information" => ["owner_id"],
        "question" => "Choose the explicit personal or corporate owner scope.",
        "execution_authorized" => false }
    end

    def projection(owner_id:, as_of: nil)
      Projection.new(events: rows("finance_events").select { |row| row["owner_id"] == owner_id },
                     catalog: catalog, as_of: timestamp(as_of))
    end

    def holdings(owner_id: nil, asset_id: nil, as_of: nil)
      owner = owner_scope(owner_id)
      return scope_clarification unless owner
      at = timestamp(as_of)
      book = projection(owner_id: owner, as_of: at)
      positions = book.positions.select { |p| !asset_id || p["asset_id"] == asset_id }.map { |p| value_position(p, at) }
      totals = positions.group_by { |p| p["asset_id"] }.map do |id, accounts|
        { "asset_id" => id, "instrument" => catalog.asset(id).data["name"],
          "quantity" => Decimal.text(accounts.sum { |p| Decimal.value(p["quantity"]) }), "accounts" => accounts }
      end
      { "status" => "ok", "owner_id" => owner, "as_of" => at, "holdings" => totals,
        "positions" => positions, "cost_basis_policy" => "fifo", "coverage" => "policy_visible_recorded_history",
        "execution_authorized" => false }
    end

    def observation(type, owner:, at:, asset_id: nil, currency: nil, base: nil)
      rows("finance_observations").select do |row|
        row["observation_type"] == type && row["owner_id"] == owner &&
          Time.iso8601(row["as_of"]) <= Time.iso8601(at) &&
          (!asset_id || row["asset_id"] == asset_id) && (!currency || row["currency"] == currency) &&
          (!base || row["base_currency"] == base)
      end.max_by { |row| [Time.iso8601(row["as_of"]), row["observation_key"]] }
    end

    def value_position(position, at)
      asset = catalog.asset(position["asset_id"])
      history = projection(owner_id: position["owner_id"], as_of: at).active_events
      price = observation("price", owner: position["owner_id"], at: at, asset_id: asset.id, currency: position["currency"])
      # Ledger valuation observations are user estimates, never transaction P&L.
      unless price
        event = history.select do |row|
          row["operation"] == "VALUATION" && row["asset_id"] == asset.id && row["owner_id"] == position["owner_id"] && row["effective_at"] <= at
        end.max_by { |row| [row["effective_at"], row["event_id"]] }
        price = event && event.merge("value" => event["price"], "as_of" => event["effective_at"], "price_type" => "user_estimate", "quality" => "estimated")
      end
      return position.merge("market_value" => nil, "unrealized_pnl" => nil, "valuation" => { "status" => "missing" }) unless price
      qty = Decimal.value(position["quantity"])
      unit_price = Decimal.value(price["value"])
      splits = history.select do |e|
        e["asset_id"] == asset.id && e["account_id"] == position["account_id"] &&
          e["operation"] == "SPLIT" && e["effective_at"] > price["as_of"]
      end
      splits.each { |split| unit_price /= Decimal.positive!(split.fetch("metadata").fetch("ratio")) }
      mark = qty * unit_price * Decimal.value(asset.data["multiplier"])
      basis = position["cost_basis"] && Decimal.value(position["cost_basis"])
      unrealized = basis && mark - basis
      futures = asset.data["asset_class"] == "future"
      market_value = Accounting.for(asset).market_value(mark, unrealized)
      position.merge(
        "asset_class" => asset.data["asset_class"], "instrument" => asset.data["name"],
        "market_value" => market_value && Decimal.text(market_value),
        "accounting_method" => Accounting.for(asset).basis_name,
        "unrealized_pnl" => unrealized && Decimal.text(unrealized),
        "notional_value" => futures ? Decimal.text(mark) : nil,
        "valuation" => {
          "status" => "available", "source" => price["source"], "as_of" => price["as_of"],
          "retrieved_at" => price["retrieved_at"], "currency" => price["currency"],
          "price" => Decimal.text(unit_price), "observed_price" => price["value"],
          "split_adjustment_events" => splits.map { |split| split["event_id"] },
          "price_type" => price["price_type"], "quality" => price["quality"],
          "freshness" => Time.iso8601(at) - Time.iso8601(price["as_of"]) > 86_400 ? "stale" : "fresh",
          "executable_quote" => false, "fx_rate" => "1"
        }
      )
    end

    def debt_report(owner_id: nil, as_of: nil, direction: nil)
      owner = owner_scope(owner_id)
      return scope_clarification unless owner
      at = timestamp(as_of)
      book = projection(owner_id: owner, as_of: at)
      entries = book.debts.keys.sort.map do |key|
        state = book.debts[key]
        terms = state["terms"]
        next if direction && terms["direction"] != direction
        counterparty = terms[terms["direction"] == "receivable" ? "debtor_id" : "creditor_id"]
        schedule = Array(terms["repayment_schedule"])
        due = schedule.select { |item| item.fetch("due_on") < at[0, 10] }.sum { |item| Decimal.value(item.fetch("principal")) }
        overdue = [[due - state["repaid"], BigDecimal("0")].max, state["principal"]].min
        {
          "owner_id" => key[0], "account_id" => key[1], "asset_id" => key[2], "currency" => key[3],
          "direction" => terms["direction"], "counterparty_id" => counterparty,
          "counterparty" => catalog.owner!(counterparty).data["name"],
          "outstanding_principal" => Decimal.text(state["principal"]), "accrued_interest" => Decimal.text(state["interest"]),
          "original_principal" => Decimal.text(state["principal"] + state["repaid"]),
          "overdue_principal" => Decimal.text(overdue), "due_dates" => schedule.map { |item| item["due_on"] },
          "collateral" => terms["collateral"], "interest_terms" => terms["interest_terms"],
          "status" => state["principal"].zero? && state["interest"].zero? ? "settled" : "outstanding"
        }
      end.compact
      { "status" => "ok", "owner_id" => owner, "as_of" => at, "debts" => entries,
        "interest_method" => "explicit_accrual_events", "execution_authorized" => false }
    end

    def convert(amount, from:, to:, owner:, at:)
      return [amount, { "rate" => "1", "base_currency" => from, "quote_currency" => to, "freshness" => "identity" }] if from == to
      fx = observation("fx", owner: owner, at: at, currency: to, base: from)
      return [nil, { "status" => "missing", "base_currency" => from, "quote_currency" => to }] unless fx
      [amount * Decimal.value(fx["value"]), fx.slice("source", "as_of", "quality").merge(
        "rate" => fx["value"], "base_currency" => from, "quote_currency" => to,
        "freshness" => Time.iso8601(at) - Time.iso8601(fx["as_of"]) > 86_400 ? "stale" : "fresh"
      )]
    end

    def networth(owner_id: nil, as_of: nil, currency: @reporting_currency)
      owner = owner_scope(owner_id)
      return scope_clarification unless owner
      at = timestamp(as_of)
      book = projection(owner_id: owner, as_of: at)
      values = book.positions.map { |p| value_position(p, at) }.map do |p|
        p.slice("asset_id", "account_id", "currency", "market_value", "valuation").merge("kind" => "asset", "value" => p["market_value"])
      end
      book.cash.keys.sort.each do |key|
        values << { "kind" => "cash", "account_id" => key[1], "currency" => key[2], "value" => Decimal.text(book.cash[key]) }
      end
      debt_report(owner_id: owner, as_of: at)["debts"].each do |debt|
        total = Decimal.value(debt["outstanding_principal"]) + Decimal.value(debt["accrued_interest"])
        total *= -1 if debt["direction"] == "payable"
        values << debt.merge("kind" => "debt", "value" => Decimal.text(total))
      end
      converted = values.map do |item|
        amount, fx = item["value"] ? convert(Decimal.value(item["value"]), from: item["currency"], to: currency, owner: owner, at: at) : [nil, nil]
        item.merge("reporting_value" => amount && Decimal.text(amount), "fx" => fx)
      end
      missing = converted.select { |item| item["reporting_value"].nil? }
      estimated = converted.any? { |item| item.dig("valuation", "quality") == "estimated" }
      stale = converted.any? { |item| item.dig("valuation", "freshness") == "stale" || item.dig("fx", "freshness") == "stale" }
      subtotal = converted.sum { |item| item["reporting_value"] ? Decimal.value(item["reporting_value"]) : BigDecimal("0") }
      { "status" => missing.empty? ? "ok" : "partial", "owner_id" => owner, "as_of" => at, "currency" => currency,
        "net_worth" => missing.empty? ? Decimal.text(subtotal) : nil,
        "known_subtotal" => Decimal.text(subtotal), "components" => converted,
        "valuation_status" => missing.any? ? "incomplete" : estimated ? "estimated" : stale ? "stale" : "observed",
        "coverage" => "policy_visible_recorded_assets_and_cash_only",
        "limitations" => ["Unrecorded assets, liabilities and cash are outside coverage; estimates are not executable prices."],
        "execution_authorized" => false }
    end

    def pnl(owner_id: nil, from:, to:, asset_id: nil, asset_ids: nil, account_id: nil)
      owner = owner_scope(owner_id)
      return scope_clarification unless owner
      start = timestamp(from, end_of_day: false)
      finish = timestamp(to)
      raise InvalidFinance, "report end precedes start" if start > finish
      opening_at = (Time.iso8601(start) - Rational(1, 1_000_000)).iso8601(6)
      before = projection(owner_id: owner, as_of: opening_at)
      after = projection(owner_id: owner, as_of: finish)
      selected = lambda do |item|
        (!asset_id || item["asset_id"] == asset_id) && (!asset_ids || asset_ids.include?(item["asset_id"])) &&
          (!account_id || item["account_id"] == account_id)
      end
      components = (after.returns + after.fees).select do |c|
        c["effective_at"] >= start && c["effective_at"] <= finish && selected.call(c)
      end
      endpoints = [before, after].map { |p| p.positions.select(&selected).map { |pos| value_position(pos, p == before ? opening_at : finish) } }
      currencies = (components.map { |c| c["currency"] } + endpoints.flatten.map { |p| p["currency"] }).uniq.sort
      totals = currencies.map do |currency|
        entries = components.select { |c| c["currency"] == currency }
        sums = %w[realized variation_margin income expense fee].to_h do |category|
          matching = entries.select { |c| c["category"] == category }
          [category, matching.all? { |c| c["amount"] } ? matching.sum { |c| Decimal.value(c["amount"]) } : nil]
        end
        marks = endpoints.map { |positions| positions.select { |p| p["currency"] == currency } }
        unrealized = marks.all? { |ps| ps.all? { |p| p["unrealized_pnl"] } } ?
          marks[1].sum { |p| Decimal.value(p["unrealized_pnl"]) } - marks[0].sum { |p| Decimal.value(p["unrealized_pnl"]) } : nil
        known = sums.values.none?(&:nil?) && !unrealized.nil?
        net = known ? sums["realized"] + sums["variation_margin"] + sums["income"] + sums["expense"] - sums["fee"] + unrealized : nil
        sums.transform_values { |n| n && Decimal.text(n) }.merge(
          "realized_pnl" => sums["realized"] && Decimal.text(sums["realized"]),
          "fees" => sums["fee"] && Decimal.text(sums["fee"]),
          "currency" => currency, "unrealized_change" => unrealized && Decimal.text(unrealized),
          "net_pnl" => net && Decimal.text(net), "fx_contribution" => nil,
          "status" => known ? "ok" : "partial"
        )
      end
      { "status" => totals.any? { |r| r["status"] == "partial" } ? "partial" : "ok",
        "owner_id" => owner, "from" => start, "to" => finish, "accounting_basis" => "FIFO gross gains; fees expensed at event date; futures daily settlement",
        "totals" => totals, "components" => components, "opening_positions" => endpoints[0], "closing_positions" => endpoints[1],
        "net_external_cash_flows" => after.flows.select { |f| f["effective_at"] >= start && f["effective_at"] <= finish },
        "limitations" => ["Native currencies remain separate; FX attribution and tax reporting are unavailable.", "Missing historical marks or cost basis make net P&L unavailable."],
        "execution_authorized" => false }
    end

    def monthly(owner_id: nil, from:, to:, asset_id: nil, asset_ids: nil, account_id: nil)
      start = Date.iso8601(from.to_s[0, 10])
      finish = Date.iso8601(to.to_s[0, 10])
      raise InvalidFinance, "report end precedes start" if finish < start
      raise InvalidFinance, "monthly report exceeds 1200 months" if (finish.year * 12 + finish.month) - (start.year * 12 + start.month) > 1200
      months = []
      cursor = Date.new(start.year, start.month, 1)
      while cursor <= finish
        ending = (cursor >> 1) - 1
        months << pnl(owner_id: owner_id, from: [start, cursor].max.iso8601, to: [finish, ending].min.iso8601,
                      asset_id: asset_id, asset_ids: asset_ids, account_id: account_id)
        cursor >>= 1
      end
      { "status" => months.any? { |m| m["status"] != "ok" } ? "partial" : "ok", "months" => months, "execution_authorized" => false }
    end

    def performance(owner_id: nil, from:, to:, currency: @reporting_currency)
      owner = owner_scope(owner_id)
      return scope_clarification unless owner
      start = timestamp(from, end_of_day: false)
      finish = timestamp(to)
      raise InvalidFinance, "report end precedes start" if start >= finish
      obs = rows("finance_observations").select do |r|
        r["owner_id"] == owner && r["observation_type"] == "portfolio" && r["currency"] == currency &&
          r["as_of"] >= start && r["as_of"] <= finish && r["quality"] == "verified"
      end.sort_by { |r| [r["as_of"], r["observation_key"]] }
      flows = projection(owner_id: owner, as_of: finish).flows.select { |f| f["effective_at"] > start && f["effective_at"] <= finish }
      twr = nil
      xirr = nil
      first = obs.find { |r| r["as_of"] == start }
      last = obs.reverse.find { |r| r["as_of"] == finish }
      if first && last && flows.all? { |f| f["currency"] == currency }
        growth = BigDecimal("1")
        previous = Decimal.positive!(first["value"])
        complete = true
        flows.sort_by { |f| [f["effective_at"], f["event_id"]] }.each do |flow|
          marks = obs.select { |r| r["as_of"] == flow["effective_at"] && r["metadata"]["flow_event_id"] == flow["event_id"] }
          prior = marks.find { |r| r["metadata"]["phase"] == "before_flow" }
          subsequent = marks.find { |r| r["metadata"]["phase"] == "after_flow" }
          if !prior || !subsequent || Decimal.value(subsequent["value"]) != Decimal.value(prior["value"]) + Decimal.value(flow["amount"])
            complete = false
            break
          end
          growth *= Decimal.positive!(prior["value"]) / previous
          previous = Decimal.positive!(subsequent["value"])
        end
        twr = (growth * Decimal.value(last["value"]) / previous - 1) if complete
        dated = [[start, -Decimal.value(first["value"])]] + flows.map { |f| [f["effective_at"], -Decimal.value(f["amount"])] } + [[finish, Decimal.value(last["value"])]]
        xirr = money_weighted(dated)
      end
      { "status" => twr ? "ok" : "unavailable", "owner_id" => owner, "from" => start, "to" => finish,
        "currency" => currency, "time_weighted_return" => twr && Decimal.text(twr.round(12)),
        "xirr" => xirr && Decimal.text(xirr.round(12)), "xirr_status" => xirr ? "available" : "unavailable",
        "methodology" => "TWR uses exact boundary and before/after-flow valuations; annual XIRR uses ACT/365 decimal bisection",
        "limitations" => ["Complete owner portfolio valuations in one currency are required; current value is never used as the return denominator."],
        "execution_authorized" => false }
    end

    def money_weighted(dated)
      # One sign transition avoids silently selecting among multiple IRRs.
      signs = dated.map { |_, n| n <=> 0 }.reject(&:zero?).chunk { |s| s }.map(&:first)
      return nil unless signs == [-1, 1]
      first_day = Date.iso8601(dated.first[0][0, 10])
      npv = lambda do |rate|
        dated.sum do |time, amount|
          years = BigDecimal((Date.iso8601(time[0, 10]) - first_day).to_i.to_s) / 365
          amount / (BigDecimal("1") + rate).power(years, 40)
        end
      end
      low = BigDecimal("-0.9999"); high = BigDecimal("1000000")
      a = npv.call(low); b = npv.call(high)
      return nil if a * b >= 0
      180.times do
        mid = (low + high) / 2
        c = npv.call(mid)
        return mid if c.abs < BigDecimal("0.00000000000001")
        if a * c > 0
          low = mid; a = c
        else
          high = mid
        end
      end
      (low + high) / 2
    end
  end
end
