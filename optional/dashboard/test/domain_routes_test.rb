# frozen_string_literal: true
require_relative "app_test"

class DashboardDomainRoutesTest < DashboardAppTest
  # Inherit transport helpers, but keep the parent tests in their original class.
  def self.runnable_methods
    super.grep(/\Atest_p3_/)
  end

  def test_p3_cursor_binding_drift_expiry_denials_and_nonmutation
    with_app(grants: %w[graph:read intelligence:read capture:read activity:read dataset:read]) do |root, app, secret, _settings, time|
      engine = create_base_entities(root, restricted: true)
      other_id = "person_00000000000000000000000002"
      engine.execute(KnowledgeGraph::CreateEntity.new(entity_type: "person", attributes: {
        id: other_id, name: "Other Synthetic", tier: "active", sensitivity: "private", data_origin: "public"
      }))
      before = Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.to_h { |path| [path, File.binread(path)] }
      cookie, csrf = login(app, secret)
      second, = login(app, secret)
      response = request(app, "GET", "/api/v1/contacts?limit=1", cookie: cookie)
      assert_equal 200, response.status, response.body
      payload = JSON.parse(response.body)
      cursor = payload.dig("data", "page", "next_cursor")
      assert_match(/\A[A-Za-z0-9_-]{43}\z/, cursor)
      refute_includes response.body, '"after"'
      page = request(app, "GET", "/api/v1/contacts?limit=1&cursor=#{cursor}", cookie: cookie)
      assert_equal [other_id], JSON.parse(page.body).dig("data", "items").map { |item| item["id"] }
      assert_equal 409, request(app, "GET", "/api/v1/contacts?limit=1&cursor=#{cursor}", cookie: second).status
      assert_equal 409, request(app, "GET", "/api/v1/contacts?limit=2&cursor=#{cursor}", cookie: cookie).status
      hidden = request(app, "GET", "/api/v1/contacts/#{RESTRICTED_PERSON_ID}", cookie: cookie)
      absent = request(app, "GET", "/api/v1/contacts/person_00000000000000000000000009", cookie: cookie)
      assert_equal 404, hidden.status
      assert_equal JSON.parse(hidden.body).reject { |key, _| key == "request_id" }, JSON.parse(absent.body).reject { |key, _| key == "request_id" }
      assert_equal 422, request(app, "GET", "/api/v1/contacts/#{PERSON_ID}/relations?depth=3", cookie: cookie).status
      assert_equal 422, request(app, "GET", "/api/v1/contacts?limit=0", cookie: cookie).status
      assert_equal 422, request(app, "GET", "/api/v1/contacts/top?as_of=2026-02-31", cookie: cookie).status
      assert_equal 422, request(app, "GET", "/api/v1/contacts?q=x&q=y", cookie: cookie).status
      assert_equal 422, request(app, "GET", "/api/v1/captures/not-an-id", cookie: cookie).status
      history = request(app, "GET", "/api/v1/activity", cookie: cookie)
      assert_equal 200, history.status, history.body
      assert_includes history.body, "dataset_activity_not_available"
      assert_equal "2026-09-25T22:00:00Z", JSON.parse(history.body).dig("window", "from")
      assert_equal "2026-10-25T23:00:00Z", JSON.parse(history.body).dig("window", "to")
      before.each { |path, bytes| assert_equal bytes, File.binread(path) }
      refute File.exist?(File.join(root, KnowledgeSDK::DATASET_PATH))
      engine.execute(KnowledgeGraph::UpdateEntity.new(entity_id: RESTRICTED_PERSON_ID, changes: { aliases: ["Hidden edit"] }))
      assert_equal 200, request(app, "GET", "/api/v1/contacts?limit=1&cursor=#{cursor}", cookie: cookie).status
      engine.execute(KnowledgeGraph::UpdateEntity.new(entity_id: other_id, changes: { aliases: ["Visible edit"] }))
      assert_equal 409, request(app, "GET", "/api/v1/contacts?limit=1&cursor=#{cursor}", cookie: cookie).status
      gateway = app.instance_variable_get(:@bridge).gateway
      original_execute = gateway.method(:execute)
      gateway.define_singleton_method(:execute) do |**options|
        response = original_execute.call(**options)
        response.capability_id == "kg.contacts.list" ? AgentPlatform::AgentResponse.new(**response.to_h.merge(capability_version: "1.1.0")) : response
      end
      version_cursor = JSON.parse(request(app, "GET", "/api/v1/contacts?limit=1", cookie: cookie).body).dig("data", "page", "next_cursor")
      gateway.define_singleton_method(:execute) { |**options| original_execute.call(**options) }
      assert_equal 409, request(app, "GET", "/api/v1/contacts?limit=1&cursor=#{version_cursor}", cookie: cookie).status
      fresh = JSON.parse(request(app, "GET", "/api/v1/contacts?limit=1", cookie: cookie).body).dig("data", "page", "next_cursor")
      time.call(301)
      assert_equal 409, request(app, "GET", "/api/v1/contacts?limit=1&cursor=#{fresh}", cookie: cookie).status
      request(app, "POST", "/api/v1/session/logout", cookie: cookie, csrf: csrf, body: {})
      assert_empty app.instance_variable_get(:@cursors).instance_variable_get(:@entries)
    end
  end

  def test_p3_missing_old_storage_permissions_windows_and_generic_vault
    with_app(schema: false, grants: %w[graph:read capture:read activity:read dataset:read]) do |root, app, secret, settings, _time|
      cookie, = login(app, secret)
      %w[contacts contacts/top captures activity].each do |route|
        response = request(app, "GET", "/api/v1/#{route}", cookie: cookie)
        assert_equal 200, response.status, response.body
      end
      refute File.exist?(File.join(root, ".knowledge"))
      FileUtils.mkdir_p(File.dirname(settings.dataset_path))
      db = SQLite3::Database.new(settings.dataset_path)
      db.execute("PRAGMA user_version = 1"); db.close
      before = File.binread(settings.dataset_path)
      response = request(app, "GET", "/api/v1/activity", cookie: cookie)
      assert_includes response.body, "dataset_activity_not_available"
      assert_equal before, File.binread(settings.dataset_path)
      assert_equal 422, request(app, "GET", "/api/v1/activity?from=2026-10-25T00:00:00", cookie: cookie).status
      assert_equal 422, request(app, "GET", "/api/v1/activity?from=2026-10-25T00:00:00&to=2026-10-26T00:00:00", cookie: cookie).status
      response = request(app, "GET", "/api/v1/activity?from=2026-03-28T23:00:00Z&to=2026-03-29T22:00:00Z", cookie: cookie)
      assert_equal 200, response.status, response.body
      assert_equal "half_open_instants", JSON.parse(response.body).dig("window", "bounds")
    end
    with_app(grants: %w[graph:read]) do |_root, app, secret, _settings, _time|
      cookie, = login(app, secret)
      response = request(app, "GET", "/api/v1/activity", cookie: cookie)
      assert_equal "unavailable", JSON.parse(response.body)["status"]
      refute_includes response.body, "dataset_storage"
      assert_equal "unavailable", JSON.parse(request(app, "GET", "/api/v1/captures", cookie: cookie).body)["status"]
    end
  end
end
