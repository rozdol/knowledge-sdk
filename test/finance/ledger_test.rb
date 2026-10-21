# frozen_string_literal: true

require_relative "test_support"

class FinanceLedgerTest < Minitest::Test
  include FinanceTestSupport

  def test_fifo_partial_close_history_and_exact_approval
    with_finance do
      rows = [event("BUY", date: "2026-01-02", quantity: "20", price: "300"),
              event("BUY", date: "2026-02-02", quantity: "15", price: "350"),
              event("SELL", date: "2026-03-02", quantity: "5", price: "400")]
      result = @finance.rows(dataset: "finance_events", rows: rows, arguments: args(JSON.generate(rows)))
      assert_empty service.rows("finance_events")
      blocked = submit_finance(result, approve: false)
      assert_equal "partially_rejected", blocked["status"]
      assert_empty service.rows("finance_events")
      submit_finance(result)
      held = service.holdings(owner_id: OWNER)["positions"].first
      assert_equal "30.0", held["quantity"]
      assert_equal "9750.0", held["cost_basis"]
      assert_equal 2, held["lots"].length
      prior = service.holdings(owner_id: OWNER, as_of: "2026-02-28")["positions"].first
      assert_equal "35.0", prior["quantity"]
      pnl = service.pnl(owner_id: OWNER, from: "2026-01-01", to: "2026-03-31")
      assert_equal "500.0", pnl["totals"].first["realized"]
      assert_nil pnl["totals"].first["net_pnl"]
      submit_finance(result)
      assert_equal 3, service.rows("finance_events").length
      assert service.rows("finance_events").all? { |r| r["approval_id"] && r["proposal_id"] && r["evidence_id"] }
    end
  end

  def test_exact_decimal_and_short_accounting
    with_finance do
      post_events([event("OPEN_SHORT", date: "2026-01-02", quantity: "0.3", price: "0.2"),
                   event("CLOSE_SHORT", date: "2026-01-03", quantity: "0.1", price: "0.1", fees: "0.001")])
      book = service.projection(owner_id: OWNER)
      assert_equal "-0.2", book.positions.first["quantity"]
      assert_equal "0.01", book.returns.first["amount"]
      assert_equal BigDecimal("0.049"), book.cash.values.first
      assert_raises(KnowledgeFinance::InvalidFinance) do
        @finance.rows(dataset: "finance_events", rows: [event("BUY", date: "2026-01-04", quantity: "1", price: 0.2)], arguments: args("Float refused"))
      end
    end
  end

  def test_transfer_preserves_fifo_and_does_not_create_profit
    with_finance do
      register_finance("account", id: SECOND_ACCOUNT, name: "Other Broker", owner_ids: [OWNER])
      post_events([event("BUY", date: "2026-01-02", quantity: "20", price: "300"),
        event("TRANSFER_OUT", date: "2026-02-02", quantity: "5", transfer_id: "synthetic-transfer"),
        event("TRANSFER_IN", date: "2026-02-02", quantity: "5", transfer_id: "synthetic-transfer", account_id: SECOND_ACCOUNT),
        event("SELL", date: "2026-03-02", quantity: "2", price: "400", account_id: SECOND_ACCOUNT)])
      book = service.projection(owner_id: OWNER)
      assert_equal ["15.0", "3.0"], book.positions.map { |p| p["quantity"] }
      assert_equal ["200.0"], book.returns.map { |r| r["amount"] }
      assert_equal "300.0", book.positions.last["average_entry_price"]
    end
  end

  def test_ledger_cannot_be_rewritten_or_written_with_forged_approval
    with_finance do
      post_events([event("BUY", date: "2026-01-02", quantity: "1", price: "10")])
      id = @datasets.describe("finance_events")["dataset_id"]
      row = service.rows("finance_events").first
      assert_raises(StructuredDataset::InvalidRow) { @datasets.delete(id, row["row_id"]) }
      assert_raises(StructuredDataset::InvalidRow) { @datasets.update(id, row["row_id"], price: "0") }
      assert_raises(StructuredDataset::InvalidRow) { @datasets.import_rows(id, [row.reject { |k, _| StructuredDataset::Definition::RESERVED_COLUMNS.include?(k) }]) }
      assert_raises(KnowledgeGraph::InvalidIntent) { @graph.execute(KnowledgeGraph::UpdateEntity.new(entity_id: ASSET, changes: { asset_class: "future" })) }
      assert_equal "10", service.rows("finance_events").first["price"]
    end
  end

  def test_unknown_basis_is_explicit_and_not_zero
    with_finance do
      post_events([event("OPENING_BALANCE", date: "2026-01-01", quantity: "5", metadata: { "confirmed" => true, "basis_status" => "unknown" }),
                   event("SELL", date: "2026-02-01", quantity: "5", price: "100")])
      book = service.projection(owner_id: OWNER)
      assert_empty book.positions
      assert_nil book.returns.first["amount"]
      assert_equal "partial", service.pnl(owner_id: OWNER, from: "2026-01-01", to: "2026-02-28")["status"]
    end
  end

  def test_no_opening_history_is_rejected_and_batch_is_atomic
    with_finance do
      post_events([event("BUY", date: "2026-01-01", quantity: "1", price: "20")])
      assert_raises(KnowledgeFinance::MissingHistory) do
        post_events([event("SELL", date: "2026-01-02", quantity: "2", price: "30")])
      end
      assert_equal 1, service.rows("finance_events").length
    end
  end
end
