# frozen_string_literal: true

require_relative "test_support"

class FinanceConversationTest < Minitest::Test
  include FinanceTestSupport

  def chat(gateway, text, context = {})
    KnowledgeGraph::ChatRouter.new(gateway: gateway).route(text, explain: true, context: args(text).merge(context))
  end

  def test_missing_gold_clarification_approval_closed_position_pnl_and_activity
    with_finance do |root|
      register_finance("asset", id: SECOND_ASSET, name: "Synthetic Gold", aliases: ["gold", "золоту"], owner_ids: [OWNER], asset_class: "precious_metal", currency: "USD", unit: "ounce", multiplier: "1")
      gateway = AgentPlatform.build(vault_root: root, clock: -> { NOW })
      context = { "conversation_id" => "synthetic-gold", "sender" => "synthetic-user" }
      first = chat(gateway, "Я закрыл позицию по золоту по 4,250.", context)
      assert_equal "clarification_required", first["status"], JSON.pretty_generate(first)
      assert_equal "finance.close_position", first.dig("result", "intent")
      missing = first.dig("result", "missing_information")
      assert_includes missing, "opening_date"
      assert_includes missing, "opening_price"
      assert_includes missing, "quantity"
      refute_includes missing, "asset_id"
      refute_includes missing, "account_id"
      assert_equal "4250", first.dig("result", "fields", "price")
      assert_empty service.rows("finance_events")
      assert_empty KnowledgeCapture::Store.new(vault_root: root).all
      second = chat(gateway, "finance details: opening_date=2026-08-01 opening_price=4000 quantity=2 effective_at=2026-09-01T12:00:00Z", context)
      assert_equal "ok", second["status"], JSON.pretty_generate(second)
      assert_equal "awaiting_approval", second.dig("result", "status")
      assert_empty service.rows("finance_events")
      submit_finance(second["result"])
      assert_equal 2, service.rows("finance_events").length
      assert_empty service.holdings(owner_id: OWNER)["positions"]
      assert_equal "500.0", service.pnl(owner_id: OWNER, from: "2026-08-01", to: "2026-09-30")["totals"].first["realized"]
      activities = KnowledgeActivity::Timeline.new(vault_root: root, clock: -> { NOW }).recent(limit: 30)
      assert_includes JSON.generate(activities.map(&:to_h)), "Financial ledger recorded immutable economic events"
    end
  end

  def test_finance_chat_search_analysis_and_historical_queries_reuse_ledger
    with_finance do |root|
      post_events([event("BUY", date: "2025-01-01", quantity: "20", price: "300"),
                   event("BUY", date: "2026-01-01", quantity: "15", price: "350"),
                   event("SELL", date: "2026-03-01", quantity: "5", price: "400")])
      gateway = AgentPlatform.build(vault_root: root, clock: -> { NOW })
      response = chat(gateway, "Сколько у меня акций Microsoft?")
      assert_equal "30.0", response.dig("result", "holdings", 0, "quantity"), JSON.pretty_generate(response)
      historical = chat(gateway, "Какие акции Microsoft у меня были в январе прошлого года?")
      assert_equal "20.0", historical.dig("result", "holdings", 0, "quantity")
      searched = StructuredDataset::Search.new(engine: @datasets, clock: -> { NOW }).query("Сколько у меня акций Microsoft?")
      assert_equal "30.0", searched.dig("answers", 0, "holdings", 0, "quantity")
      analysis = KnowledgeAnalysis::Engine.new(vault_root: root, dataset_engine: @datasets, clock: -> { NOW }).analyze("Monthly investment P&L for the past year")
      assert_equal "finance", analysis.dig("analysis", "domain_reports", 0, "domain"), JSON.pretty_generate(analysis)
      refute_empty analysis.dig("analysis", "domain_reports", 0, "report", "months")
      again = KnowledgeAnalysis::Engine.new(vault_root: root, dataset_engine: @datasets, clock: -> { NOW }).analyze("Monthly investment P&L for the past year")
      assert_equal analysis, again
    end
  end

  def test_ambiguous_assets_and_owners_are_never_combined
    with_finance do |root|
      register_finance("asset", id: SECOND_ASSET, name: "Other Microsoft", aliases: ["MSFT"], owner_ids: [OWNER], asset_class: "stock", currency: "USD", unit: "share", multiplier: "1", identifiers: [{ type: "ticker_mic", value: "MSFT:XALT" }])
      response = chat(AgentPlatform.build(vault_root: root), "How many MSFT shares do I have?")
      assert_equal "clarification_required", response["status"]
      assert_equal 2, response.dig("result", "candidates").length
      corporate = "financialowner_01KYYD4HNT4HEWNH1P3DQKTPPG"
      register_finance("owner", id: corporate, name: "Synthetic Company", owner_kind: "corporate")
      register_finance("account", id: SECOND_ACCOUNT, name: "Company Account", owner_ids: [corporate])
      assert_equal "clarification_required", service.holdings["status"]
      assert_equal OWNER, service.holdings(owner_id: OWNER)["owner_id"]
    end
  end

  def test_finance_routes_do_not_claim_explicit_capture_or_expenses
    classifier = KnowledgeGraph::ChatIntentResolver.new
    assert_equal "knowledge.capture", classifier.resolve("Note: I bought shares and want to remember this idea.").intent
    assert_equal "dataset.expense", classifier.resolve("I spent 40 EUR on lunch").intent
    assert_equal "finance.open_position", classifier.resolve("Я купил 30 акций Microsoft по 420 долларов").intent
    assert_equal "finance.plan_liquidity", classifier.resolve("Что мне продать, чтобы быстро получить 70,000 EUR?").intent
    assert_equal "finance.query_performance", classifier.resolve("Сколько заработал на опционах ES в сентябре?").intent
    window = KnowledgeFinance::Window.new("Сколько заработал на опционах ES в сентябре?", NOW.to_date)
    assert_equal "2026-09-01", window.from
    assert_equal "2026-09-30", window.to
    quarter = KnowledgeFinance::Window.new("Что принесло наибольшую прибыль за прошлый квартал?", NOW.to_date)
    assert_equal "2026-07-01", quarter.from
    assert_equal "2026-09-30", quarter.to
  end

  def test_instrument_performance_does_not_include_unrelated_gains
    with_finance do |root|
      register_finance("asset", id: SECOND_ASSET, name: "Other Equity", owner_ids: [OWNER], asset_class: "stock", currency: "USD", unit: "share", multiplier: "1")
      post_events([event("BUY", date: "2026-03-01", quantity: "5", price: "300"),
                   event("SELL", date: "2026-03-02", quantity: "5", price: "400"),
                   event("BUY", date: "2026-03-01", quantity: "10", price: "100", asset_id: SECOND_ASSET),
                   event("SELL", date: "2026-03-02", quantity: "10", price: "200", asset_id: SECOND_ASSET)])
      response = KnowledgeFinance::Conversation.new(vault_root: root, clock: -> { NOW }).read("content" => "Microsoft investment profit in March 2026")
      assert_equal "500.0", response["totals"].first["realized"]
      analysis = KnowledgeAnalysis::Engine.new(vault_root: root, clock: -> { NOW }).analyze("Microsoft investment profit in March 2026")
      assert_equal "500.0", analysis.dig("analysis", "domain_reports", 0, "report", "totals", 0, "realized")
    end
  end
end
