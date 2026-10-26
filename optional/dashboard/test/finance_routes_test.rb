# frozen_string_literal: true
require_relative "app_test"
require_relative "../../../test/finance/test_support"

class DashboardFinanceRoutesTest < DashboardAppTest
  include FinanceTestSupport

  def self.runnable_methods
    super.grep(/\Atest_p4_/)
  end

  def test_p4_scopes_reports_cursors_permissions_and_utc_defaults
    with_app(grants: %w[graph:read finance:read dataset:read]) do |root, app, secret, settings, _time|
      KnowledgeSDK::PluginRegistry.new.install("finance", root)
      @finance_root = root
      @graph = KnowledgeGraph::Engine.new(vault_root: root, clock: -> { FinanceTestSupport::NOW })
      @datasets = StructuredDataset::Engine.new(vault_root: root, clock: -> { FinanceTestSupport::NOW })
      @finance = KnowledgeFinance::Proposals.new(vault_root: root, dataset_engine: @datasets, clock: -> { FinanceTestSupport::NOW })
      register_finance("owner", id: OWNER, name: "Synthetic Owner", owner_kind: "personal")
      register_finance("account", id: ACCOUNT, name: "Broker", owner_ids: [OWNER])
      register_finance("asset", id: ASSET, name: "Synthetic Stock", owner_ids: [OWNER], asset_class: "stock", currency: "USD", unit: "share", multiplier: "1")
      post_events([event("BUY", date: "2026-10-01", quantity: "0.3", price: "0.2"), event("SELL", date: "2026-10-25", quantity: "0.1", price: "0.4")])
      before = @datasets.query("finance_events", limit: 100)
      notes = Dir.glob(File.join(root, "**/*.md")).to_h { |path| [path, File.binread(path)] }
      cookie, = login(app, secret)
      scopes = request(app, "GET", "/api/v1/finance/scopes", cookie: cookie)
      assert_equal [OWNER], JSON.parse(scopes.body).dig("data", "owners").map { |item| item["id"] }
      first = request(app, "GET", "/api/v1/finance/transactions?owner_id=#{OWNER}&limit=1", cookie: cookie)
      assert_equal 200, first.status, first.body
      body = JSON.parse(first.body)
      assert_equal "2026-09-26", body.dig("window", "from")
      assert_equal "2026-10-25", body.dig("window", "to")
      assert_equal "Etc/UTC", body.dig("window", "timezone")
      assert_equal "inclusive_dates", body.dig("window", "bounds")
      assert_equal OWNER, body.dig("scope", "owner_id")
      cursor = body.dig("data", "page", "next_cursor")
      assert_match(/\A[A-Za-z0-9_-]{43}\z/, cursor)
      second = request(app, "GET", "/api/v1/finance/transactions?owner_id=#{OWNER}&limit=1&cursor=#{cursor}", cookie: cookie)
      assert_equal "BUY", JSON.parse(second.body).dig("data", "items", 0, "operation")
      assert_equal 409, request(app, "GET", "/api/v1/finance/transactions?owner_id=#{OWNER}&limit=2&cursor=#{cursor}", cookie: cookie).status
      %w[positions liabilities net-worth pnl].each do |route|
        response = request(app, "GET", "/api/v1/finance/#{route}?owner_id=#{OWNER}", cookie: cookie)
        assert_equal 200, response.status, response.body
        assert_equal 422, request(app, "GET", "/api/v1/finance/#{route}", cookie: cookie).status
      end
      invalid = request(app, "GET", "/api/v1/finance/pnl?owner_id=#{OWNER}&from=2026-10-01T00:00:00&to=2026-10-25", cookie: cookie)
      assert_equal 422, invalid.status, invalid.body
      assert_equal 422, request(app, "GET", "/api/v1/finance/net-worth?owner_id=#{OWNER}&currency=usd", cookie: cookie).status
      assert_equal before.sort_by { |row| row["row_id"] }, @datasets.query("finance_events", limit: 100).sort_by { |row| row["row_id"] }
      post_events([event("BUY", date: "2026-10-25", quantity: "0.1", price: "0.2")])
      assert_equal 409, request(app, "GET", "/api/v1/finance/transactions?owner_id=#{OWNER}&limit=1&cursor=#{cursor}", cookie: cookie).status
      assert_equal notes, Dir.glob(File.join(root, "**/*.md")).to_h { |path| [path, File.binread(path)] }
      db = SQLite3::Database.new(settings.dataset_path); db.execute("PRAGMA user_version = 1"); db.close
      bytes = File.binread(settings.dataset_path)
      response = request(app, "GET", "/api/v1/finance/net-worth?owner_id=#{OWNER}", cookie: cookie)
      assert_includes response.body, "dataset_upgrade_required"
      assert_equal bytes, File.binread(settings.dataset_path)
    end
    with_app(grants: %w[graph:read]) do |root, app, secret, _settings, _time|
      cookie, = login(app, secret)
      response = request(app, "GET", "/api/v1/finance/scopes", cookie: cookie)
      assert_equal "unavailable", JSON.parse(response.body)["status"]
      refute File.exist?(File.join(root, ".knowledge"))
    end
  end
end
