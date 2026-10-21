# frozen_string_literal: true

module KnowledgeFinance
  # Pure FIFO replay. No state is saved; all quantities and cash are derived.
  class Projection
    OPEN_LONG = %w[BUY OPEN_LONG ASSET_ACQUISITION OPENING_BALANCE].freeze
    CLOSE_LONG = %w[SELL CLOSE_LONG ASSET_DISPOSAL].freeze
    INCOME = %w[DIVIDEND COUPON INTEREST_RECEIVED RENTAL_INCOME].freeze
    EXPENSE = %w[FEE TAX_WITHHELD INTEREST_PAID MAINTENANCE_EXPENSE].freeze
    OPERATIONS = (OPEN_LONG + CLOSE_LONG + INCOME + EXPENSE + %w[
      OPEN_SHORT CLOSE_SHORT TRANSFER_IN TRANSFER_OUT DEPOSIT WITHDRAWAL SPLIT
      OPTION_EXPIRATION OPTION_EXERCISE OPTION_ASSIGNMENT FUTURES_VARIATION_MARGIN
      LOAN_DISBURSEMENT LOAN_REPAYMENT INTEREST_ACCRUAL VALUATION OWNERSHIP_CHANGE
      REVERSAL CORPORATE_ACTION MERGER SPIN_OFF CORRECTION
    ]).freeze
    UNSUPPORTED = %w[CORPORATE_ACTION MERGER SPIN_OFF CORRECTION OWNERSHIP_CHANGE].freeze
    attr_reader :lots, :cash, :debts, :returns, :flows, :fees, :events, :active_events

    def initialize(events:, catalog:, as_of: nil, cost_basis: "fifo")
      raise InvalidFinance, "only fifo cost basis is currently supported" unless cost_basis == "fifo"
      @catalog = catalog.snapshot
      cutoff = as_of && Time.iso8601(as_of.to_s)
      @events = events.select { |e| !cutoff || Time.iso8601(e.fetch("effective_at")) <= cutoff }
      @events = @events.sort_by { |e| [Time.iso8601(e.fetch("effective_at")), e.fetch("sequence", 0), e.fetch("event_id")] }
      @events.each { |event| Rows.validate_event!(event, @catalog) }
      @lots = Hash.new { |h, k| h[k] = [] }
      @cash = Hash.new { |h, k| h[k] = BigDecimal("0") }
      @debts = {}
      @returns = []
      @flows = []
      @fees = []
      @transfers = {}
      replay
    end

    def positions
      lots.keys.sort.map do |key|
        remaining = lots[key].reject { |lot| lot[:quantity].zero? }
        next if remaining.empty?
        qty = remaining.sum { |lot| lot[:quantity] }
        known = remaining.all? { |lot| !lot[:price].nil? }
        multiplier = Decimal.value(@catalog.asset(key[2]).data.fetch("multiplier"))
        basis = known ? remaining.sum { |lot| lot[:quantity] * lot[:price] * multiplier } : nil
        {
          "owner_id" => key[0], "account_id" => key[1], "asset_id" => key[2], "currency" => key[3],
          "quantity" => Decimal.text(qty), "cost_basis" => basis && Decimal.text(basis),
          "average_entry_price" => basis && Decimal.text(basis / qty / multiplier),
          "cost_basis_policy" => "fifo", "basis_status" => known ? "known" : "unknown",
          "lots" => remaining.map do |lot|
            { "opening_event_id" => lot[:event_id], "quantity" => Decimal.text(lot[:quantity]),
              "price" => lot[:price] && Decimal.text(lot[:price]), "opened_at" => lot[:opened_at] }
          end
        }
      end.compact
    end

    private

    def replay
      ids = events.map { |e| e.fetch("event_id") }
      raise InvalidFinance, "duplicate economic event ID" unless ids.uniq == ids
      reversed = {}
      events.select { |e| e["operation"] == "REVERSAL" }.each do |reversal|
        target = events.find { |e| e["event_id"] == reversal["reverses_event_id"] }
        raise InvalidFinance, "reversal target is absent or itself a reversal" unless target && target["operation"] != "REVERSAL"
        raise InvalidFinance, "event has already been reversed" if reversed[target["event_id"]]
        raise InvalidFinance, "reversal cannot predate its target" if Time.iso8601(reversal["effective_at"]) < Time.iso8601(target["effective_at"])
        %w[owner_id account_id asset_id currency].each do |field|
          raise InvalidFinance, "reversal scope differs from target" unless reversal[field] == target[field]
        end
        reversed[target["event_id"]] = true
      end
      events.select { |e| e["correction_of"] }.each do |correction|
        raise InvalidFinance, "correction requires an atomic linked reversal" unless reversed[correction["correction_of"]]
      end
      active = events.reject { |e| e["operation"] == "REVERSAL" || reversed[e["event_id"]] }
      @active_events = active
      validate_transfers!(active)
      active.each do |event|
        apply(event)
        if @catalog.asset(event["asset_id"]).data["unit"] == "ownership_share"
          quantity = @lots.select { |key, _| key[2] == event["asset_id"] }.values.flatten.sum { |lot| lot[:quantity] }
          raise InvalidFinance, "fractional ownership must remain between zero and one" if quantity < 0 || quantity > 1
        end
      end
    end

    def apply(event)
      op = event.fetch("operation")
      raise InvalidFinance, "unsupported operation requires an explicit supported posting bundle: #{op}" if UNSUPPORTED.include?(op)
      instrument = @catalog.asset(event.fetch("asset_id"))
      klass = instrument.data.fetch("asset_class")
      accounting = Accounting.for(instrument)
      key = event.values_at("owner_id", "account_id", "asset_id", "currency")
      cash_key = event.values_at("owner_id", "account_id", "currency")
      quantity = Decimal.value(event.fetch("quantity"))
      amount = event["amount"] && Decimal.value(event["amount"])
      price = event["price"] && Decimal.value(event["price"])
      multiplier = Decimal.value(instrument.data.fetch("multiplier"))
      fee = Decimal.value(event.fetch("fees"))
      @cash[cash_key] -= fee
      @fees << component(event, fee) unless fee.zero?
      if OPEN_LONG.include?(op) || op == "OPEN_SHORT"
        sign = op == "OPEN_SHORT" ? -1 : 1
        raise InvalidFinance, "close the opposite position explicitly first" if @lots[key].any? { |l| l[:quantity] * sign < 0 }
        @lots[key] << { quantity: quantity * sign, price: price, event_id: event["event_id"], opened_at: event["effective_at"] }
        unless op == "OPENING_BALANCE"
          @cash[cash_key] += accounting.opening_cash(quantity * multiplier, price, sign)
        end
      elsif CLOSE_LONG.include?(op) || %w[CLOSE_SHORT OPTION_EXPIRATION OPTION_EXERCISE OPTION_ASSIGNMENT].include?(op)
        sign = %w[CLOSE_SHORT OPTION_ASSIGNMENT].include?(op) ? -1 : 1
        if %w[OPTION_EXERCISE OPTION_ASSIGNMENT].include?(op)
          terms = @catalog.details(instrument)
          raise InvalidFinance, "physical option settlement requires a separately modeled posting bundle" unless
            %w[option futures_option].include?(klass) && terms["settlement"] == "cash"
          underlying_price = Decimal.value(event.fetch("metadata")["underlying_settlement_price"])
          strike = Decimal.value(terms.fetch("strike"))
          intrinsic = [terms["put_call"] == "call" ? underlying_price - strike : strike - underlying_price, BigDecimal("0")].max
          raise InvalidFinance, "option settlement price conflicts with contract terms" if price && price != intrinsic
          price = intrinsic
        end
        if op == "OPTION_EXPIRATION"
          raise InvalidFinance, "expiration applies only to options" unless %w[option futures_option].include?(klass)
          raise InvalidFinance, "expiration cannot precede expiry" if event["effective_at"][0, 10] < @catalog.details(instrument).fetch("expiry")
          sign = @lots[key].sum { |l| l[:quantity] } < 0 ? -1 : 1
          price = BigDecimal("0")
        end
        closed = take_lots(key, quantity, sign)
        profit = closed.all? { |lot| lot[:price] } ? closed.sum { |lot| (price - lot[:price]) * lot[:quantity] * multiplier } : nil
        @returns << component(event, profit, "realized")
        @cash[cash_key] += accounting.closing_cash(quantity * multiplier, price, sign, profit)
      elsif op == "SPLIT"
        raise InvalidFinance, "splits require equity instruments" unless %w[stock etf mutual_fund].include?(klass)
        ratio = Decimal.positive!(event.fetch("metadata").fetch("ratio"))
        @lots[key].each { |lot| lot[:quantity] *= ratio; lot[:price] /= ratio if lot[:price] }
      elsif op == "FUTURES_VARIATION_MARGIN"
        raise InvalidFinance, "variation margin requires a future and settlement price" unless klass == "future" && price && amount
        raise MissingHistory, "variation margin has no opening position" if @lots[key].empty?
        raise InvalidFinance, "futures basis is unknown" unless @lots[key].all? { |l| l[:price] }
        expected = @lots[key].sum { |lot| (price - lot[:price]) * lot[:quantity] * multiplier }
        raise InvalidFinance, "variation margin does not reconcile to settlement price" unless expected == amount
        @lots[key].each { |lot| lot[:price] = price }
        @cash[cash_key] += amount
        @returns << component(event, amount, "variation_margin")
      elsif INCOME.include?(op) || EXPENSE.include?(op)
        raise InvalidFinance, "income and expense events require amount" unless amount && amount >= 0
        direction = INCOME.include?(op) ? 1 : -1
        @cash[cash_key] += amount * direction
        @returns << component(event, amount * direction, direction == 1 ? "income" : "expense")
      elsif %w[DEPOSIT WITHDRAWAL].include?(op)
        raise InvalidFinance, "external cash flow requires amount and cash asset" unless amount && amount > 0 && klass == "cash"
        signed = amount * (op == "DEPOSIT" ? 1 : -1)
        @cash[cash_key] += signed
        @flows << component(event, signed, "external_flow")
      elsif %w[TRANSFER_IN TRANSFER_OUT].include?(op)
        transfer(event, key, cash_key, klass, quantity, amount)
      elsif %w[LOAN_DISBURSEMENT LOAN_REPAYMENT INTEREST_ACCRUAL].include?(op)
        debt(event, key, cash_key, instrument, amount)
      elsif op != "VALUATION"
        raise InvalidFinance, "unknown financial operation"
      end
    end

    def take_lots(key, quantity, sign)
      available = @lots[key].sum { |lot| lot[:quantity] * sign }
      raise MissingHistory, "insufficient opening position history" if available < quantity || available <= 0
      needed = quantity
      result = []
      @lots[key].each do |lot|
        break if needed.zero?
        next if lot[:quantity].zero?
        used = [needed, lot[:quantity].abs].min
        result << lot.merge(quantity: used * sign)
        lot[:quantity] -= used * sign
        needed -= used
      end
      @lots[key].reject! { |lot| lot[:quantity].zero? }
      result
    end

    def transfer(event, key, cash_key, klass, qty, amount)
      sign = event["operation"] == "TRANSFER_IN" ? 1 : -1
      if klass == "cash"
        raise InvalidFinance, "cash transfer requires amount" unless amount && amount > 0
        @cash[cash_key] += amount * sign
      elsif sign == -1
        direction = event["metadata"]["position_side"] == "short" ? -1 : 1
        @transfers[event["transfer_id"]] = take_lots(key, qty, direction)
      else
        transferred = @transfers.delete(event["transfer_id"])
        raise InvalidFinance, "transfer out must precede transfer in" unless transferred
        if @lots[key].any? { |lot| transferred.any? { |incoming| lot[:quantity] * incoming[:quantity] < 0 } }
          raise InvalidFinance, "transfer cannot implicitly close an opposite position"
        end
        @lots[key].concat(transferred)
      end
    end

    def validate_transfers!(active)
      active.select { |e| %w[TRANSFER_IN TRANSFER_OUT].include?(e["operation"]) }.group_by { |e| e["transfer_id"] }.each do |id, pair|
        raise InvalidFinance, "transfer requires exactly one in and one out" unless id && pair.map { |e| e["operation"] }.sort == %w[TRANSFER_IN TRANSFER_OUT]
        %w[owner_id asset_id currency quantity amount effective_at].each do |field|
          raise InvalidFinance, "transfer legs do not reconcile" unless pair[0][field] == pair[1][field]
        end
        unless pair[0].fetch("metadata")["position_side"] == pair[1].fetch("metadata")["position_side"]
          raise InvalidFinance, "transfer position sides differ"
        end
        raise InvalidFinance, "transfer accounts must differ" if pair[0]["account_id"] == pair[1]["account_id"]
      end
    end

    def debt(event, key, cash_key, instrument, amount)
      raise InvalidFinance, "debt event requires a loan asset and nonnegative amount" unless
        %w[loan credit_card credit_facility].include?(instrument.data["asset_class"]) && amount && amount >= 0
      terms = @catalog.details(instrument)
      state = (@debts[key] ||= { "principal" => BigDecimal("0"), "interest" => BigDecimal("0"), "repaid" => BigDecimal("0"), "terms" => terms })
      sign = terms["direction"] == "receivable" ? 1 : -1
      case event["operation"]
      when "LOAN_DISBURSEMENT"
        state["principal"] += amount
        @cash[cash_key] -= amount * sign
      when "INTEREST_ACCRUAL"
        state["interest"] += amount
      when "LOAN_REPAYMENT"
        interest = Decimal.value(event.fetch("metadata").fetch("interest", "0"))
        raise InvalidFinance, "repayment exceeds known principal/interest" if amount > state["principal"] || interest > state["interest"] || interest < 0
        state["principal"] -= amount
        state["repaid"] += amount
        state["interest"] -= interest
        @cash[cash_key] += (amount + interest) * sign
        @returns << component(event, interest * sign, "income") unless interest.zero?
      end
    end

    def component(event, amount, category = "fee")
      event.slice("event_id", "owner_id", "account_id", "asset_id", "currency", "effective_at").merge(
        "amount" => amount && Decimal.text(amount), "category" => category
      )
    end
  end
end
