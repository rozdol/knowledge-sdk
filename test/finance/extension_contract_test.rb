# frozen_string_literal: true

require_relative "test_support"

class FinanceExtensionContractTest < Minitest::Test
  include FinanceTestSupport

  def test_flex_statement_requires_exact_mappings_and_approved_import
    with_finance do |root|
      register_finance("account", id: SECOND_ACCOUNT, name: "Synthetic IBKR", owner_ids: [OWNER], identifiers: [{ type: "broker_account", value: "IBKR:SYNTH-U0001" }])
      register_finance("asset", id: SECOND_ASSET, name: "Synthetic IBKR Equity", owner_ids: [OWNER], asset_class: "stock", currency: "USD", unit: "share", multiplier: "1", identifiers: [{ type: "conid", value: "999000001" }])
      xml = <<~XML
        <FlexQueryResponse><FlexStatements><FlexStatement accountId="SYNTH-U0001">
          <Trades><Trade conid="999000001" buySell="BUY" openCloseIndicator="O" quantity="5" tradePrice="100" ibCommission="-1" ibCommissionCurrency="USD" currency="USD" dateTime="20260101;120000" ibExecID="SYNTH-EXEC-1" tradeID="SYNTH-TRADE-1"/></Trades>
          <CashTransactions><CashTransaction conid="999000001" type="Dividends" amount="12.5" currency="USD" dateTime="2026-09-01T12:00:00Z" transactionID="SYNTH-DIV-1"/></CashTransactions>
        </FlexStatement></FlexStatements></FlexQueryResponse>
      XML
      path = File.join(root, "synthetic-flex.xml"); File.write(path, xml)
      importer = KnowledgeFinance::Importer.new(proposals: @finance)
      assert_raises(KnowledgeFinance::InvalidFinance) { importer.propose(path: path, owner_id: OWNER, account_id: SECOND_ACCOUNT) }
      result = importer.propose(path: path, owner_id: OWNER, account_id: SECOND_ACCOUNT, timezone_offset: "+02:00")
      assert_empty service.rows("finance_events")
      submit_finance(result)
      rows = service.rows("finance_events")
      assert_equal 2, rows.length
      trade = rows.find { |r| r["operation"] == "OPEN_LONG" }
      assert_equal "2026-01-01T10:00:00.000000Z", trade["effective_at"]
      assert_equal "999000001", trade["metadata"]["conid"]
      assert_equal "SYNTH-EXEC-1", trade["external_event_id"]
      assert_equal "1.0", trade["fees"]
      File.write(path, '<!DOCTYPE bad [<!ENTITY x SYSTEM "file:///synthetic">]>' + xml)
      assert_raises(KnowledgeFinance::InvalidFinance) { importer.propose(path: path, owner_id: OWNER, account_id: SECOND_ACCOUNT) }
    end
  end

  def test_cash_settled_option_exercise_uses_contract_intrinsic_value
    with_finance do
      register_finance("asset", id: SECOND_ASSET, name: "Synthetic Cash Call", owner_ids: [OWNER], asset_class: "option", currency: "USD", unit: "contract", multiplier: "100",
        details: { underlying_id: ASSET, exchange: "XTEST", expiry: "2026-09-18", strike: "100", put_call: "call", settlement: "cash" })
      post_events([event("OPEN_LONG", date: "2026-09-01", quantity: "2", price: "5", asset_id: SECOND_ASSET, unit: "contract"),
                   event("OPTION_EXERCISE", date: "2026-09-18", quantity: "2", asset_id: SECOND_ASSET, unit: "contract", metadata: { "underlying_settlement_price" => "110" })])
      assert_empty service.projection(owner_id: OWNER).positions
      assert_equal "1000.0", service.pnl(owner_id: OWNER, from: "2026-09-01", to: "2026-09-30")["totals"].first["realized"]
      assert_equal BigDecimal("1000"), service.projection(owner_id: OWNER).cash.values.first
    end
  end

  def test_dirty_price_bond_and_coupon_have_exact_native_pnl
    with_finance do
      register_finance("asset", id: SECOND_ASSET, name: "Synthetic Bond", owner_ids: [OWNER], asset_class: "bond", currency: "USD", unit: "nominal", multiplier: "0.01",
        details: { issuer_id: OWNER, maturity: "2030-01-01", coupon: "0.05", price_basis: "dirty_per_100" })
      post_events([event("BUY", date: "2026-01-01", quantity: "1000", price: "99", asset_id: SECOND_ASSET, unit: "nominal"),
                   event("COUPON", date: "2026-06-01", amount: "25", asset_id: SECOND_ASSET, unit: "nominal"),
                   event("SELL", date: "2026-09-01", quantity: "1000", price: "101", asset_id: SECOND_ASSET, unit: "nominal")])
      totals = service.pnl(owner_id: OWNER, from: "2026-01-01", to: "2026-09-30")["totals"].first
      assert_equal "20.0", totals["realized"]
      assert_equal "25.0", totals["income"]
      assert_equal "45.0", totals["net_pnl"]
    end
  end

  def test_correction_retains_original_event_and_rollback_on_concurrent_position_drift
    with_finance do
      original = post_events([event("BUY", date: "2026-01-01", quantity: "5", price: "300")])
      old_id = service.rows("finance_events").first["event_id"]
      post_events([event("REVERSAL", date: "2026-01-01", reverses_event_id: old_id),
                   event("BUY", date: "2026-01-01", quantity: "5", price: "310", correction_of: old_id)])
      assert_equal 3, service.rows("finance_events").length
      assert_equal "310.0", service.holdings(owner_id: OWNER)["positions"].first["average_entry_price"]
      close = [event("SELL", date: "2026-02-01", quantity: "5", price: "400")]
      reviewed = @finance.rows(dataset: "finance_events", rows: close, arguments: args("Reviewed close"))
      post_events([event("SELL", date: "2026-01-30", quantity: "5", price: "390")])
      @finance.store.approve(proposal_id: reviewed["proposal_id"], intent_ids: @finance.store.load(reviewed["proposal_id"])["planned_intents"].map { |p| p["planned_intent_id"] }, actor_id: "finance-human")
      receipt = KnowledgeExtraction::ProposalSubmitter.new(engine: @graph, store: @finance.store, dataset_engine: @datasets).submit(reviewed["proposal_id"])
      assert_equal "failed", receipt["results"].first["status"]
      assert_equal 4, service.rows("finance_events").length
      assert_empty service.holdings(owner_id: OWNER)["positions"]
    end
  end

  def test_schema_pattern_round_trip_is_stable
    schema = KnowledgeFinance::Schemas.events
    5.times do
      round_trip = StructuredDataset::Definition.from_h(JSON.parse(JSON.generate(schema.to_h)))
      assert_equal schema.to_h, round_trip.to_h
      schema = round_trip
    end
  end

  def test_financial_risk_policy_retains_human_review
    batch = KnowledgeGraph::AppendFinanceRows.new(dataset: "finance_events", rows: [], source: "synthetic", observation_id: "synthetic")
    assert_equal "medium", KnowledgeExtraction::RiskClassifier.new.classify(batch)
    reversal = KnowledgeGraph::AppendFinanceRows.new(dataset: "finance_events", rows: [{ "operation" => "REVERSAL" }], source: "synthetic", observation_id: "synthetic")
    assert_equal "high", KnowledgeExtraction::RiskClassifier.new.classify(reversal)
  end

  def test_splits_adjust_pre_split_marks_once_per_account
    with_finance do
      register_finance("account", id: SECOND_ACCOUNT, name: "Other Split Account", owner_ids: [OWNER])
      post_events([event("BUY", date: "2026-01-01", quantity: "20", price: "300"),
                   event("BUY", date: "2026-01-01", quantity: "10", price: "300", account_id: SECOND_ACCOUNT),
                   event("SPLIT", date: "2026-02-01", metadata: { "ratio" => "2" }),
                   event("SPLIT", date: "2026-02-01", account_id: SECOND_ACCOUNT, metadata: { "ratio" => "2" })])
      post_observations([observation(value: "300", as_of: "2026-01-31T12:00:00Z")])
      holdings = service.holdings(owner_id: OWNER)["positions"]
      assert_equal ["40.0", "20.0"], holdings.map { |p| p["quantity"] }
      assert holdings.all? { |p| p["valuation"]["price"] == "150.0" }
      assert_equal "0.0", service.pnl(owner_id: OWNER, from: "2026-01-01", to: "2026-02-28")["totals"].first["unrealized_change"]
    end
  end

  def test_external_contract_drift_does_not_reinterpret_recorded_cash_or_positions
    with_finance do |root|
      post_events([event("BUY", date: "2026-01-01", quantity: "1", price: "100")])
      record = @finance.service.catalog.asset(ASSET)
      # Simulate an external human edit after review; the SDK itself refuses it.
      File.write(File.join(root, record.relative_path), KnowledgeGraph::YamlWriter.new.render(record.data.merge("multiplier" => "100"), body: record.body))
      assert_raises(KnowledgeFinance::InvalidFinance) { service.holdings(owner_id: OWNER) }
    end
  end

  def test_short_lot_transfer_and_same_day_close
    with_finance do
      register_finance("account", id: SECOND_ACCOUNT, name: "Other Short Account", owner_ids: [OWNER])
      post_events([event("OPEN_SHORT", date: "2026-01-01", quantity: "2", price: "50"),
                   event("TRANSFER_OUT", date: "2026-01-01", quantity: "1", transfer_id: "short-transfer", metadata: { "position_side" => "short" }),
                   event("TRANSFER_IN", date: "2026-01-01", quantity: "1", transfer_id: "short-transfer", account_id: SECOND_ACCOUNT, metadata: { "position_side" => "short" }),
                   event("CLOSE_SHORT", date: "2026-01-01", quantity: "1", price: "40", account_id: SECOND_ACCOUNT)])
      assert_equal "-1.0", service.holdings(owner_id: OWNER)["positions"].first["quantity"]
      assert_equal "10.0", service.pnl(owner_id: OWNER, from: "2026-01-01", to: "2026-01-01")["totals"].first["realized"]
    end
  end

  def test_generic_vault_installation_and_conflict_preflight
    with_vault do |root|
      KnowledgeSDK::PluginRegistry.new.install("finance", root)
      @finance_root = root
      @graph = KnowledgeGraph::Engine.new(vault_root: root, clock: -> { NOW })
      @datasets = StructuredDataset::Engine.new(vault_root: root, clock: -> { NOW })
      @finance = KnowledgeFinance::Proposals.new(vault_root: root, dataset_engine: @datasets, clock: -> { NOW })
      register_finance("owner", id: OWNER, name: "Synthetic Generic Owner", owner_kind: "personal")
      register_finance("account", id: ACCOUNT, name: "Synthetic Generic Account", owner_ids: [OWNER])
      register_finance("asset", id: ASSET, name: "Generic Equity", owner_ids: [OWNER], asset_class: "etf", currency: "USD", unit: "share", multiplier: "1")
      post_events([event("BUY", date: "2026-01-01", quantity: "1", price: "100")])
      assert_equal "1.0", service.holdings(owner_id: OWNER)["positions"].first["quantity"]
      assert_equal "generic", KnowledgeSDK.validator_path(root).parent.basename.to_s
      assert_raises(KnowledgeSDK::PluginError) { KnowledgeSDK::PluginRegistry.new.install("finance", root) }
      assert_equal "1.0", service.holdings(owner_id: OWNER)["positions"].first["quantity"]
    end
  end
end
