# frozen_string_literal: true

require_relative "test_support"

class FinanceDomainsTest < Minitest::Test
  include FinanceTestSupport
  PARTY = "financialowner_01KYYD4HNT4HEWNH1P3DQKTPPG"

  def test_futures_daily_settlement_partial_close_and_no_double_count
    with_finance do
      register_finance("asset", id: SECOND_ASSET, name: "Synthetic Future", owner_ids: [OWNER], asset_class: "future", currency: "USD", unit: "contract", multiplier: "50",
                       identifiers: [{ type: "conid", value: "123456789" }], details: { exchange: "XTEST", contract_month: "202612", expiry: "2026-12-18" })
      common = { asset_id: SECOND_ASSET, unit: "contract" }
      post_events([event("OPEN_LONG", date: "2026-09-01", quantity: "2", price: "5000", **common),
                   event("FUTURES_VARIATION_MARGIN", date: "2026-09-02", price: "5010", amount: "1000", **common),
                   event("CLOSE_LONG", date: "2026-09-03", quantity: "1", price: "5020", **common)])
      post_observations([observation(asset_id: SECOND_ASSET, value: "5020", as_of: "2026-09-03T12:00:00Z")])
      report = service.pnl(owner_id: OWNER, from: "2026-09-01", to: "2026-09-30")["totals"].first
      assert_equal "1000.0", report["variation_margin"]
      assert_equal "500.0", report["realized"]
      assert_equal "500.0", report["unrealized_change"]
      assert_equal "2000.0", report["net_pnl"]
      assert_equal BigDecimal("1500"), service.projection(owner_id: OWNER).cash.values.first
      assert_equal "1.0", service.holdings(owner_id: OWNER)["positions"].first["quantity"]
    end
  end

  def test_multiple_option_legs_expire_and_physical_exercise_refuses_to_guess
    with_finance do
      third = "financialasset_01KYYD4HNT4HEWNH1P3DQKTPPH"
      [SECOND_ASSET, third].each_with_index do |id, i|
        register_finance("asset", id: id, name: "Synthetic Call #{i}", owner_ids: [OWNER], asset_class: "option", currency: "USD", unit: "contract", multiplier: "100",
          details: { underlying_id: ASSET, exchange: "XTEST", expiry: "2026-09-18", strike: i == 0 ? "500" : "550", put_call: "call", settlement: "physical" })
      end
      post_events([event("OPEN_LONG", date: "2026-09-01", quantity: "1", price: "10", asset_id: SECOND_ASSET, unit: "contract"),
                   event("OPEN_SHORT", date: "2026-09-01", quantity: "1", price: "4", asset_id: third, unit: "contract"),
                   event("OPTION_EXPIRATION", date: "2026-09-18", quantity: "1", asset_id: SECOND_ASSET, unit: "contract"),
                   event("OPTION_EXPIRATION", date: "2026-09-18", quantity: "1", asset_id: third, unit: "contract")])
      assert_empty service.projection(owner_id: OWNER).positions
      totals = service.pnl(owner_id: OWNER, from: "2026-09-01", to: "2026-09-30")["totals"].first
      assert_equal "-600.0", totals["realized"]
      assert_equal "-600.0", totals["net_pnl"]
      assert_raises(KnowledgeFinance::InvalidFinance) do
        post_events([event("OPTION_EXERCISE", date: "2026-09-18", quantity: "1", asset_id: SECOND_ASSET, unit: "contract")])
      end
    end
  end

  def test_receivable_and_payable_keep_principal_interest_and_arrears_separate
    with_finance do
      register_finance("owner", id: PARTY, name: "Synthetic Counterparty", owner_kind: "personal")
      register_finance("asset", id: SECOND_ASSET, name: "Synthetic Receivable", owner_ids: [OWNER], asset_class: "loan", currency: "EUR", unit: "principal", multiplier: "1",
        details: { creditor_id: OWNER, debtor_id: PARTY, direction: "receivable", agreement_date: "2026-01-01", repayment_schedule: [{ due_on: "2026-09-01", principal: "5000" }] })
      base = { asset_id: SECOND_ASSET, unit: "principal", currency: "EUR" }
      post_events([event("LOAN_DISBURSEMENT", date: "2026-01-01", amount: "5000", **base),
                   event("INTEREST_ACCRUAL", date: "2026-08-01", amount: "100", **base),
                   event("LOAN_REPAYMENT", date: "2026-08-02", amount: "2000", metadata: { "interest" => "25" }, **base)])
      debt = service.debt_report(owner_id: OWNER)["debts"].first
      assert_equal "3000.0", debt["outstanding_principal"]
      assert_equal "75.0", debt["accrued_interest"]
      assert_equal "3000.0", debt["overdue_principal"]
      response = KnowledgeFinance::Conversation.new(vault_root: @finance_root, clock: -> { NOW }).read("content" => "Кто мне должен?")
      assert_equal PARTY, response["debts"].first["counterparty_id"]
      third = "financialasset_01KYYD4HNT4HEWNH1P3DQKTPPH"
      register_finance("asset", id: third, name: "Synthetic Mortgage", owner_ids: [OWNER], asset_class: "loan", currency: "EUR", unit: "principal", multiplier: "1",
        details: { creditor_id: PARTY, debtor_id: OWNER, direction: "payable", agreement_date: "2026-01-01", collateral: ["synthetic-title"] })
      post_events([event("LOAN_DISBURSEMENT", date: "2026-01-01", amount: "10000", **base.merge(asset_id: third)),
                   event("INTEREST_ACCRUAL", date: "2026-08-01", amount: "100", **base.merge(asset_id: third)),
                   event("LOAN_REPAYMENT", date: "2026-08-02", amount: "2000", metadata: { "interest" => "50" }, **base.merge(asset_id: third))])
      payable = service.debt_report(owner_id: OWNER, direction: "payable")["debts"].first
      assert_equal "8000.0", payable["outstanding_principal"]
      assert_equal "50.0", payable["accrued_interest"]
    end
  end

  def test_property_fraction_and_estimates_are_not_realized_profit
    with_finance do
      register_finance("owner", id: PARTY, name: "Synthetic Joint Owner", owner_kind: "personal")
      register_finance("asset", id: SECOND_ASSET, name: "Synthetic Property", owner_ids: [OWNER, PARTY], asset_class: "real_estate", currency: "EUR", unit: "ownership_share", multiplier: "1",
        identifiers: [{ type: "cadastral", jurisdiction: "CY", value: "SYNTHETIC-LOT-42" }], details: { jurisdiction: "CY" })
      post_events([event("ASSET_ACQUISITION", date: "2026-01-01", quantity: "0.5", price: "200000", asset_id: SECOND_ASSET, unit: "ownership_share", currency: "EUR"),
                   event("VALUATION", date: "2026-09-01", price: "250000", asset_id: SECOND_ASSET, unit: "ownership_share", currency: "EUR")])
      property = service.holdings(owner_id: OWNER)["positions"].first
      assert_equal "125000.0", property["market_value"]
      assert_equal "user_estimate", property["valuation"]["price_type"]
      assert_equal false, property["valuation"]["executable_quote"]
      report = service.pnl(owner_id: OWNER, from: "2026-01-01", to: "2026-09-30")
      assert_equal "0.0", report["totals"].first["realized"]
      assert_equal "25000.0", report["totals"].first["unrealized_change"]
      assert_equal "25000.0", service.networth(owner_id: OWNER)["net_worth"]
    end
  end

  def test_historical_price_never_uses_future_price_and_fx_is_explicit
    with_finance do
      post_events([event("BUY", date: "2026-01-01", quantity: "1", price: "100")])
      post_observations([observation(value: "200", as_of: "2026-10-01T12:00:00Z")])
      assert_nil service.holdings(owner_id: OWNER, as_of: "2026-02-01")["positions"].first["market_value"]
      partial = service.networth(owner_id: OWNER)
      assert_nil partial["net_worth"]
      assert_equal "partial", partial["status"]
      post_observations([observation(type: "fx", asset_id: nil, value: "0.9", currency: "EUR", base_currency: "USD")])
      valued = service.networth(owner_id: OWNER)
      assert_equal "90.0", valued["net_worth"]
      assert_equal "0.9", valued["components"].first["fx"]["rate"]
    end
  end
end
