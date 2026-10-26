# frozen_string_literal: true
require_relative "test_support"
require_relative "../finance/test_support"

class FinanceReadsTest < Minitest::Test
  include FinanceTestSupport
  GRANTS = %w[graph:read dataset:read finance:read].freeze

  def typed(root, name, arguments = {}, grants: GRANTS)
    gateway = AgentPlatform.build(vault_root: root, environment: "read_only", clock: -> { FinanceTestSupport::NOW })
    agent = AgentPlatform::AgentIdentity.new(id: "finance-reader", permissions: grants)
    invoke(gateway, agent, "kg.finance.#{name}", arguments)
  end

  def payload(root, name, arguments = {}, **options)
    response = typed(root, name, arguments, **options)
    assert response.success?, response.to_h.inspect
    response.payload
  end

  def test_transfer_fifo_exact_values_parity_and_paging_after_replay_without_writers
    with_finance do |root|
      register_finance("account", id: SECOND_ACCOUNT, name: "Other Broker", owner_ids: [OWNER])
      post_events([event("BUY", date: "2026-01-01", quantity: "0.3", price: "0.2", fees: "0.001"),
        event("TRANSFER_OUT", date: "2026-02-01", quantity: "0.1", transfer_id: "synthetic-transfer"),
        event("TRANSFER_IN", date: "2026-02-01", quantity: "0.1", transfer_id: "synthetic-transfer", account_id: SECOND_ACCOUNT),
        event("SELL", date: "2026-03-01", quantity: "0.05", price: "0.4", account_id: SECOND_ACCOUNT)])
      post_observations([observation(value: "0.4", as_of: "2026-10-20T12:00:00Z")])
      expected = service.holdings(owner_id: OWNER, as_of: "2026-10-21")["positions"]
      worth = service.networth(owner_id: OWNER, as_of: "2026-10-21", currency: "USD")
      returns = service.pnl(owner_id: OWNER, from: "2026-01-01", to: "2026-10-21", account_id: SECOND_ACCOUNT)
      before = canonical_bytes(root)
      refuse = ->(**_options) { flunk "typed Finance constructed a writer" }
      KnowledgeGraph::Engine.stub(:new, refuse) do
        KnowledgeExtraction::ProposalStore.stub(:new, refuse) do
          StructuredDataset::Engine.stub(:new, refuse) do
            scope = payload(root, "scopes")
            assert_equal [OWNER], scope.dig("data", "owners").map { |item| item["id"] }
            %w[identifiers_json details_json].each { |key| refute_includes JSON.generate(scope), key }
            first = payload(root, "positions", "owner_id" => OWNER, "limit" => 1, "as_of" => "2026-10-21")
            second = payload(root, "positions", "owner_id" => OWNER, "limit" => 1, "as_of" => "2026-10-21", "after" => first.dig("data", "page", "after"))
            assert_equal expected.map { |p| p["quantity"] }, (first.dig("data", "items") + second.dig("data", "items")).map { |p| p["quantity"] }
            assert_equal first["source_version"], second["source_version"]
            filtered = payload(root, "positions", "owner_id" => OWNER, "account_id" => SECOND_ACCOUNT)
            assert_equal "0.05", filtered.dig("data", "items", 0, "quantity")
            assert_equal "0.01", filtered.dig("data", "items", 0, "cost_basis")
            assert_equal "share", filtered.dig("data", "items", 0, "unit")
            net = payload(root, "net_worth", "owner_id" => OWNER, "as_of" => "2026-10-21", "currency" => "USD")
            assert_equal worth["net_worth"], net.dig("data", "net_worth")
            pnl = payload(root, "pnl", "owner_id" => OWNER, "account_id" => SECOND_ACCOUNT, "from" => "2026-01-01", "to" => "2026-10-21")
            assert_equal returns["totals"], pnl.dig("data", "totals")
            transactions = payload(root, "transactions", "owner_id" => OWNER, "account_id" => SECOND_ACCOUNT, "from" => "2026-03-01", "to" => "2026-03-01", "limit" => 1)
            assert_equal ["SELL"], transactions.dig("data", "items").map { |row| row["operation"] }
            refute_includes JSON.generate(transactions), "asset_contract_digest"
            refute_includes JSON.generate(transactions), "source_uri"
            assert_equal "empty", payload(root, "liabilities", "owner_id" => OWNER)["data"]["debts"].empty? ? "empty" : "nonempty"
          end
        end
      end
      assert_equal before, canonical_bytes(root)
    end
  end

  def test_missing_basis_marks_fx_monthly_and_invalid_time_contracts
    with_finance do |root|
      post_events([event("OPENING_BALANCE", date: "2026-01-01", quantity: "2", metadata: { "confirmed" => true, "basis_status" => "unknown" })])
      positions = payload(root, "positions", "owner_id" => OWNER)
      assert_equal "partial", positions["status"]
      assert_nil positions.dig("data", "items", 0, "cost_basis")
      worth = payload(root, "net_worth", "owner_id" => OWNER)
      assert_nil worth.dig("data", "net_worth")
      assert_equal "0.0", worth.dig("data", "known_subtotal")
      monthly = payload(root, "pnl", "owner_id" => OWNER, "from" => "2026-01-01", "to" => "2026-02-28", "period" => "monthly")
      assert_equal 2, monthly.dig("data", "months").length
      assert_nil monthly.dig("data", "months", 0, "totals", 0, "net_pnl")
      [{}, { "owner_id" => OWNER, "as_of" => "2026-02-31" }, { "owner_id" => OWNER, "as_of" => "2026-01-01T00:00:00" }].each do |args|
        assert_equal "InvalidArguments", typed(root, "positions", args).errors.first["code"]
      end
      assert_equal "InvalidArguments", typed(root, "pnl", "owner_id" => OWNER, "from" => "2020-01-01", "to" => "2026-01-01").errors.first["code"]
      assert_equal "InvalidArguments", typed(root, "pnl", "owner_id" => OWNER, "currency" => "USD").errors.first["code"]
    end
  end

  def test_restricted_grants_hidden_versions_and_uniform_scope_denials
    with_finance do |root|
      post_events([event("BUY", date: "2026-01-01", quantity: "1", price: "76543.21", sensitivity: "restricted")])
      plain = payload(root, "positions", "owner_id" => OWNER)
      assert_empty plain.dig("data", "items")
      %w[finance:restricted graph:restricted dataset:restricted].each do |grant|
        assert_equal plain, payload(root, "positions", { "owner_id" => OWNER }, grants: GRANTS + [grant])
      end
      full = payload(root, "positions", { "owner_id" => OWNER }, grants: GRANTS + %w[finance:restricted graph:restricted dataset:restricted])
      assert_equal "76543.21", full.dig("data", "items", 0, "lots", 0, "price")
      post_events([event("BUY", date: "2026-01-02", quantity: "1", price: "88888", sensitivity: "restricted")])
      assert_equal plain, payload(root, "positions", "owner_id" => OWNER)
      hidden_owner = "financialowner_00000000000000000000000001"
      register_finance("owner", id: hidden_owner, name: "Hidden owner", owner_kind: "personal", sensitivity: "restricted")
      hidden = typed(root, "positions", "owner_id" => hidden_owner)
      absent = typed(root, "positions", "owner_id" => "financialowner_00000000000000000000000002")
      assert_equal hidden.errors, absent.errors
      assert_equal "PolicyDenied", hidden.errors.first["code"]
      assert_equal "PolicyDenied", typed(root, "positions", "owner_id" => hidden_owner, "account_id" => ACCOUNT).errors.first["code"]
      agent = AgentPlatform::AgentIdentity.new(id: "denied", permissions: %w[graph:read dataset:read])
      refute AgentPlatform.build(vault_root: root).discover(agent: agent).any? { |m| m["capability_id"].start_with?("kg.finance.") }
    end
  end

  def test_missing_outdated_storage_and_missing_registration_never_initialize
    with_finance do |root|
      assert_equal "unavailable", payload(root, "net_worth", "owner_id" => OWNER)["status"]
      post_events([event("BUY", date: "2026-01-01", quantity: "1", price: "20")])
      path = File.join(root, KnowledgeSDK::DATASET_PATH)
      db = SQLite3::Database.new(path)
      db.execute("PRAGMA user_version = 1"); db.close
      before = File.binread(path)
      assert_includes payload(root, "positions", "owner_id" => OWNER)["limitations"], "dataset_upgrade_required"
      assert_equal before, File.binread(path)
    end
    with_schema_vault do |root|
      KnowledgeSDK::PluginRegistry.new.install("finance", root)
      before = Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH)
      assert_equal "empty", payload(root, "scopes")["status"]
      assert_equal before, Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH)
      refute File.exist?(File.join(root, ".knowledge"))
    end
  end

  def test_loans_two_owners_native_currencies_and_hidden_contract_references
    with_finance do |root|
      party = "financialowner_00000000000000000000000001"
      register_finance("owner", id: party, name: "Synthetic counterparty", owner_kind: "corporate")
      register_finance("asset", id: SECOND_ASSET, name: "Synthetic receivable", owner_ids: [OWNER], asset_class: "loan", currency: "EUR", unit: "principal", multiplier: "1",
        details: { creditor_id: OWNER, debtor_id: party, direction: "receivable", agreement_date: "2026-01-01" })
      post_events([event("BUY", date: "2026-01-01", quantity: "1", price: "20"),
        event("LOAN_DISBURSEMENT", date: "2026-01-01", asset_id: SECOND_ASSET, unit: "principal", currency: "EUR", amount: "1000"),
        event("INTEREST_ACCRUAL", date: "2026-02-01", asset_id: SECOND_ASSET, unit: "principal", currency: "EUR", amount: "5"),
        event("INTEREST_RECEIVED", date: "2026-03-01", asset_id: SECOND_ASSET, unit: "principal", currency: "EUR", amount: "1")])
      debts = payload(root, "liabilities", "owner_id" => OWNER)
      assert_equal service.debt_report(owner_id: OWNER)["debts"].first["outstanding_principal"], debts.dig("data", "debts", 0, "outstanding_principal")
      assert_equal "5.0", debts.dig("data", "debts", 0, "accrued_interest")
      assert_empty payload(root, "liabilities", "owner_id" => OWNER, "direction" => "payable").dig("data", "debts")
      pnl = payload(root, "pnl", "owner_id" => OWNER, "from" => "2026-01-01", "to" => "2026-10-21")
      assert_equal %w[EUR USD], pnl.dig("data", "totals").map { |item| item["currency"] }
      assert_equal "PolicyDenied", typed(root, "positions", "owner_id" => party, "account_id" => ACCOUNT).errors.first["code"]
      # Simulate a hostile external edit: a public contract pointing to a hidden
      # counterparty must disappear before both scope selection and replay.
      record = KnowledgeGraph::Repository.new(vault_root: root, registry: KnowledgeGraph::SchemaRegistry.new(vault_root: root)).resolve(party)
      file = File.expand_path(record.relative_path, root)
      File.write(file, YAML.dump(record.data.merge("sensitivity" => "restricted")) + "---\n" + record.body)
      scopes = payload(root, "scopes")
      refute_includes JSON.generate(scopes), party
      refute_includes JSON.generate(scopes), SECOND_ASSET
      assert_empty payload(root, "liabilities", "owner_id" => OWNER).dig("data", "debts")
    end
  end

  def test_replay_ceiling_refuses_instead_of_truncating
    with_finance do |root|
      post_events([event("BUY", date: "2026-01-01", quantity: "1", price: "20")])
      row = @datasets.query("finance_events", limit: 1).first
      reader = StructuredDataset::Reader.new(vault_root: root, database_path: File.join(root, KnowledgeSDK::DATASET_PATH))
      calls = 0
      reader.stub(:query, ->(*_args, **_options) { calls += 1; Array.new(10_000, row) }) do
        StructuredDataset::Reader.stub(:new, reader) do
          result = payload(root, "positions", "owner_id" => OWNER, "limit" => 1)
          assert_equal "unavailable", result["status"]
          assert_includes result["limitations"], "finance_replay_bound_reached"
          assert_nil result["data"]
        end
      end
      assert_equal 10, calls
    end
  end

  def canonical_bytes(root)
    Dir.glob(File.join(root, "**/*.md")).sort.to_h { |path| [path, File.binread(path)] }
  end
end
