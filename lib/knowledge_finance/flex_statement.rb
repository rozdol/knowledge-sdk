# frozen_string_literal: true

require "rexml/document"

module KnowledgeFinance
  # Bounded, offline subset of IBKR Flex. Exact account and conId mappings are
  # mandatory. Unknown sections/records cannot silently become opening trades.
  class FlexStatement
    def initialize(catalog:, owner_id:, account_id:, timezone_offset: nil)
      @catalog = catalog
      @owner_id = owner_id
      @timezone_offset = timezone_offset
      if timezone_offset && !timezone_offset.match?(/\A[+-](?:0[0-9]|1[0-4]):[0-5][0-9]\z/)
        raise InvalidFinance, "statement timezone offset must be explicit, for example +02:00"
      end
      @account = catalog.resolve(account_id, "financial_account")
      catalog.owner!(owner_id)
      raise InvalidFinance, "Flex account does not belong to owner" unless Array(@account.data["owner_ids"]).include?(owner_id)
      @account_identifiers = JSON.parse(@account.data.fetch("identifiers_json", "[]")).select { |i| i["type"] == "broker_account" }.map { |i| i["value"] }
    end

    def parse(xml)
      raise InvalidFinance, "Flex XML declarations with DTD or entities are refused" if xml.match?(/<!\s*(?:DOCTYPE|ENTITY)/i)
      document = REXML::Document.new(xml)
      statements = REXML::XPath.match(document, "//FlexStatement")
      raise InvalidFinance, "Flex contains no statements" if statements.empty?
      rows = []
      statements.each do |statement|
        broker_account = statement.attributes["accountId"]
        unless @account_identifiers.include?(broker_account) || @account_identifiers.include?("IBKR:#{broker_account}")
          raise InvalidFinance, "Flex accountId must exactly match the registered broker_account identifier"
        end
        # Snapshot positions are reconciled separately, never imported as trades.
        if REXML::XPath.match(statement, "OpenPositions/OpenPosition").any?
          raise InvalidFinance, "Flex positions require a separate snapshot reconciliation; export Transactions only"
        end
        REXML::XPath.match(statement, "Trades/Trade").each { |trade| rows << trade_event(trade) }
        REXML::XPath.match(statement, "CashTransactions/CashTransaction").each { |cash| rows << cash_event(cash) }
        unsupported = statement.elements.to_a.map(&:name) - %w[Trades CashTransactions AccountInformation SecuritiesInfo]
        raise InvalidFinance, "unsupported Flex section requires normalization: #{unsupported.join(', ')}" unless unsupported.empty?
      end
      raise InvalidFinance, "Flex requires 1..10000 supported events" unless rows.length.between?(1, 10_000)
      rows
    rescue REXML::ParseException
      raise InvalidFinance, "invalid Flex XML"
    end

    private

    def asset(conid)
      candidates = @catalog.records("financial_asset").select do |record|
        JSON.parse(record.data.fetch("identifiers_json", "[]")).any? { |id| id["type"] == "conid" && id["value"] == conid }
      end
      raise InvalidFinance, "Flex conId must identify exactly one registered instrument" unless conid && candidates.length == 1
      candidates.first
    end

    def base(element)
      instrument = asset(element.attributes["conid"])
      time = element.attributes["dateTime"] || element.attributes["tradeDate"]
      if time.to_s.match?(/\A\d{8};\d{6}\z/)
        raise InvalidFinance, "Flex broker-local timestamps require --statement-offset or per-row ISO normalization" unless @timezone_offset
        raw = time
        time = "#{raw[0, 4]}-#{raw[4, 2]}-#{raw[6, 2]}T#{raw[9, 2]}:#{raw[11, 2]}:#{raw[13, 2]}#{@timezone_offset}"
      end
      raise InvalidFinance, "Flex timestamp timezone is missing" unless time.to_s.match?(/(?:Z|[+-][0-9]{2}:[0-9]{2})\z/)
      effective = Time.iso8601(time.to_s).utc.iso8601(6)
      { "owner_id" => @owner_id, "account_id" => @account.id, "asset_id" => instrument.id,
        "currency" => element.attributes["currency"], "unit" => instrument.data["unit"],
        "effective_at" => effective, "quantity" => "0", "metadata" => { "broker" => "IBKR", "conid" => element.attributes["conid"], "statement_timezone_offset" => @timezone_offset } }
    rescue ArgumentError
      raise InvalidFinance, "Flex event requires an ISO timestamp with timezone"
    end

    def trade_event(element)
      row = base(element)
      side = element.attributes["buySell"]
      opening = element.attributes["openCloseIndicator"]
      raise InvalidFinance, "Flex buySell must be BUY or SELL" unless %w[BUY SELL].include?(side)
      op = case [opening, side]
           when ["O", "BUY"] then "OPEN_LONG"
           when ["O", "SELL"] then "OPEN_SHORT"
           when ["C", "SELL"] then "CLOSE_LONG"
           when ["C", "BUY"] then "CLOSE_SHORT"
           else raise InvalidFinance, "Flex openCloseIndicator is required; position direction is not guessed"
           end
      fee = element.attributes["ibCommission"]
      raise InvalidFinance, "Flex commission and commission currency are required" unless fee && element.attributes["ibCommissionCurrency"] == row["currency"]
      quantity = Decimal.value(element.attributes["quantity"]).abs
      execution = element.attributes["ibExecID"] || element.attributes["tradeID"]
      raise InvalidFinance, "Flex trade requires execution/trade ID" if execution.to_s.empty?
      row.merge("operation" => op, "quantity" => Decimal.text(quantity), "price" => element.attributes["tradePrice"],
                "fees" => Decimal.text(Decimal.value(fee).abs), "external_event_id" => execution,
                "metadata" => row["metadata"].merge("execution_id" => execution, "trade_id" => element.attributes["tradeID"], "broker_proceeds" => element.attributes["proceeds"]))
    end

    def cash_event(element)
      op = { "Dividends" => "DIVIDEND", "Withholding Tax" => "TAX_WITHHELD", "Bond Coupon" => "COUPON",
             "Broker Interest Received" => "INTEREST_RECEIVED", "Broker Interest Paid" => "INTEREST_PAID", "Fees" => "FEE" }[element.attributes["type"]]
      raise InvalidFinance, "Flex cash transaction type requires explicit normalization" unless op
      row = base(element)
      external = element.attributes["transactionID"]
      raise InvalidFinance, "Flex cash transaction ID is required" if external.to_s.empty?
      row.merge("operation" => op, "amount" => Decimal.text(Decimal.value(element.attributes["amount"]).abs),
                "external_event_id" => external, "fees" => "0")
    end
  end
end
