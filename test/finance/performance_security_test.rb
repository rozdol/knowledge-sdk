# frozen_string_literal: true

require_relative "test_support"

class FinancePerformanceSecurityTest < Minitest::Test
  include FinanceTestSupport

  def cash_asset
    register_finance("asset", id: SECOND_ASSET, name: "Synthetic EUR Cash", owner_ids: [OWNER], asset_class: "cash", currency: "EUR", unit: "EUR", multiplier: "1")
  end

  def test_time_weighted_returns_and_cash_flows
    with_finance do
      cash_asset
      posted = post_events([event("DEPOSIT", date: "2025-07-01", amount: "500", asset_id: SECOND_ASSET, unit: "EUR", currency: "EUR")])
      flow_id = service.rows("finance_events").first["event_id"]
      base = { type: "portfolio", asset_id: nil, currency: "EUR", price_type: "portfolio_close" }
      post_observations([
        observation(value: "1000", as_of: "2025-01-01T00:00:00Z", **base),
        observation(value: "1100", as_of: "2025-07-01T12:00:00Z", metadata: { "phase" => "before_flow", "flow_event_id" => flow_id }, **base),
        observation(value: "1600", as_of: "2025-07-01T12:00:00Z", metadata: { "phase" => "after_flow", "flow_event_id" => flow_id }, **base),
        observation(value: "1760", as_of: "2026-01-01T00:00:00Z", **base)
      ])
      report = service.performance(owner_id: OWNER, from: "2025-01-01T00:00:00Z", to: "2026-01-01T00:00:00Z", currency: "EUR")
      assert_equal "0.21", report["time_weighted_return"]
      assert_equal "available", report["xirr_status"]
      assert_operator BigDecimal(report["xirr"]), :>, BigDecimal("0.20")
      assert_operator BigDecimal(report["xirr"]), :<, BigDecimal("0.22")
      assert_equal "unavailable", service.performance(owner_id: OWNER, from: "2025-01-02", to: "2026-01-01")["status"]
      assert_empty service.pnl(owner_id: OWNER, from: "2025-01-01", to: "2026-01-01")["totals"]
      assert_equal 1, service.pnl(owner_id: OWNER, from: "2025-01-01", to: "2026-01-01")["net_external_cash_flows"].length
    end
  end

  def test_liquidity_uses_existing_planning_and_creates_no_transactions
    settings = { liquidity: { accessible: true, permissions_confirmed: true, settlement_days: 2,
                 commission_rate: "0.001", fx_cost_rate: "0.002", unit_step: "1", withdrawable_cash_confirmed: true } }
    with_finance(account_details: settings) do
      cash_asset
      post_events([event("BUY", date: "2026-01-01", quantity: "200", price: "300"),
                   event("DEPOSIT", date: "2026-01-02", amount: "20000", asset_id: SECOND_ASSET, currency: "EUR", unit: "EUR")])
      post_observations([observation(value: "400", as_of: NOW.iso8601(6), price_type: "bid"),
                         observation(type: "fx", asset_id: nil, value: "0.9", currency: "EUR", base_currency: "USD", as_of: NOW.iso8601(6))])
      count = service.rows("finance_events").length
      result = service.liquidity(owner_id: OWNER, target: "70000", as_of: NOW.iso8601(6), deadline: "2026-10-25")
      assert_equal 2, result["scenarios"].length
      assert result["scenarios"].all? { |s| s["target_met"] }
      assert result["scenarios"].all? { |s| BigDecimal(s["estimated_net_cash"]) >= BigDecimal("70000") }
      assert_equal false, result["execution_authorized"]
      assert_equal count, service.rows("finance_events").length
      assert result["planning_policy"]
      refute_includes JSON.generate(result), '"type":"AppendFinanceRows"'
      unmet = service.liquidity(owner_id: OWNER, target: "1000000", as_of: NOW.iso8601(6))
      assert unmet["scenarios"].all? { |s| s["target_met"] == false }
    end
  end

  def test_identifiers_checksums_scope_and_typed_contracts
    ids = KnowledgeFinance::Identifiers.new
    assert ids.isin?("US5949181045")
    refute ids.isin?("US5949181046")
    # Generated jurisdiction checksum over a clearly synthetic bank/account code.
    bban = "000000000000000001"
    check = 98 - Integer(bban + "131400", 10) % 97
    iban = "DE#{check.to_s.rjust(2, '0')}#{bban}"
    assert ids.iban?(iban)
    refute ids.iban?(iban + "0")
    assert_raises(KnowledgeFinance::InvalidFinance) { ids.validate([{ type: "ticker_mic", value: "MSFT" }]) }
    assert_raises(KnowledgeFinance::InvalidFinance) { ids.validate([{ type: "vin", value: "INVALID-I-O-Q" }]) }
    ids.register_cadastral("TEST") { |value| value.match?(/\ASYNTH-[0-9]+\z/) }
    ids.validate([{ type: "cadastral", jurisdiction: "TEST", value: "SYNTH-42" }])
    assert_raises(KnowledgeFinance::InvalidFinance) { ids.validate([{ type: "cadastral", jurisdiction: "TEST", value: "wrong" }]) }
  end

  def test_normalized_import_dedup_conflict_and_snapshot_reconciliation
    with_finance do |root|
      file = File.join(root, "synthetic-statement.csv")
      rows = [event("BUY", date: "2026-01-01", quantity: "5", price: "300", external_event_id: "SYNTH-EXEC-1")]
      CSV.open(file, "w") do |csv|
        csv << rows.first.keys
        rows.each { |row| csv << row.values }
      end
      importer = KnowledgeFinance::Importer.new(proposals: @finance)
      proposal = importer.propose(path: file, source: "synthetic-broker")
      assert_empty service.rows("finance_events")
      submit_finance(proposal)
      submit_finance(importer.propose(path: file, source: "synthetic-broker"))
      assert_equal 1, service.rows("finance_events").length
      reconciliation = importer.reconcile(snapshots: [{ "account_id" => ACCOUNT, "asset_id" => ASSET, "currency" => "USD", "quantity" => "8" }], owner_id: OWNER, as_of: "2026-10-01")
      assert_equal "unresolved", reconciliation["status"]
      assert_equal "3.0", reconciliation["rows"].first["difference"]
      assert_equal false, reconciliation["history_created"]
      rows.first["price"] = "301"
      conflict = @finance.rows(dataset: "finance_events", rows: rows, arguments: args("Conflicting statement").merge("origin_source" => "synthetic-broker"))
      receipt = submit_finance(conflict, approve: false)
      assert_equal "partially_rejected", receipt["status"]
      @finance.store.approve(proposal_id: conflict["proposal_id"], intent_ids: @finance.store.load(conflict["proposal_id"])["planned_intents"].map { |p| p["planned_intent_id"] }, actor_id: "finance-human")
      receipt = KnowledgeExtraction::ProposalSubmitter.new(engine: @graph, store: @finance.store, dataset_engine: @datasets).submit(conflict["proposal_id"])
      assert_equal "failed", receipt["results"].last["status"]
      assert_equal "300", service.rows("finance_events").first["price"]
    end
  end

  def test_restricted_rows_stay_out_of_gateway_analysis_activity_evidence_and_telemetry
    with_finance do |root|
      secret = "76543.21"
      post_events([event("BUY", date: "2026-01-01", quantity: "1", price: secret, sensitivity: "restricted")])
      assert_empty service.rows("finance_events")
      assert_equal 1, service(include_restricted: true).rows("finance_events").length
      telemetry = AgentPlatform::TelemetryRecorder.new
      gateway = AgentPlatform.build(vault_root: root, clock: -> { NOW }, telemetry: telemetry)
      result = KnowledgeGraph::ChatRouter.new(gateway: gateway).route("Сколько у меня акций Microsoft?", context: args("query"))
      refute_includes JSON.generate(result), secret
      assert_empty result.dig("result", "positions")
      activities = KnowledgeActivity::Timeline.new(vault_root: root, clock: -> { NOW })
      activities.recent(limit: 30).each { |a| refute_includes JSON.generate(activities.explain(a)), secret }
      analysis = KnowledgeAnalysis::Engine.new(vault_root: root, clock: -> { NOW }).analyze("Monthly investment P&L")
      refute_includes JSON.generate(analysis), secret
      unprivileged = AgentPlatform::AgentIdentity.new(id: "external", permissions: %w[graph:read dataset:read])
      refute gateway.discover(agent: unprivileged).any? { |m| m["capability_id"].start_with?("kg.finance.") }
      refute_includes JSON.generate(telemetry.instance_variable_get(:@events)), secret
    end
  end

  def test_vaults_with_overlapping_ids_remain_isolated
    with_finance do |first|
      post_events([event("BUY", date: "2026-01-01", quantity: "7", price: "100")])
      reader = KnowledgeFinance::Service.new(vault_root: first)
      with_finance do
        post_events([event("BUY", date: "2026-01-01", quantity: "2", price: "200")])
        assert_equal "7.0", reader.holdings(owner_id: OWNER)["positions"].first["quantity"]
        assert_equal "2.0", service.holdings(owner_id: OWNER)["positions"].first["quantity"]
      end
    end
  end

  def test_clarification_state_is_actor_scoped_and_preserves_restricted_sensitivity
    with_finance do |root|
      gateway = AgentPlatform.build(vault_root: root, clock: -> { NOW })
      invoke = lambda do |agent, arguments|
        contract = gateway.discover(agent: agent).find { |m| m["capability_id"] == "kg.finance.propose" }
        request = gateway.issue_request(invocation_token: contract["invocation_token"], arguments: arguments)
        gateway.execute(request: request, agent: agent)
      end
      secret = "76543.21"
      private_args = args("I closed my Microsoft position at #{secret}").merge("conversation_id" => "shared", "sender" => "sender", "sensitivity" => "restricted")
      admin = AgentPlatform::AgentIdentity.new(id: "first-actor", permissions: ["*"])
      initial = invoke.call(admin, private_args)
      assert initial.success?
      assert_equal "clarification_required", initial.payload["status"]
      second = AgentPlatform::AgentIdentity.new(id: "other-actor", permissions: %w[finance:create proposal:create dataset:read graph:read])
      reply = args("finance details: quantity=1").merge("conversation_id" => "shared", "sender" => "sender")
      result = invoke.call(second, reply)
      refute_includes JSON.generate(result.to_h), secret
      downgraded = AgentPlatform::AgentIdentity.new(id: "first-actor", permissions: second.permissions)
      refused = invoke.call(downgraded, reply)
      refute refused.success?
      refute_includes JSON.generate(refused.to_h), secret
    end
  end
end
