# frozen_string_literal: true

require_relative "../../../test/agent_platform/test_support"
require "rack/mock"
require "knowledge_sdk/dashboard"
require "sqlite3"
require "socket"
require "net/http"
require "timeout"

class DashboardAppTest < Minitest::Test
  def test_packaged_shell_and_hashed_asset_boundary
    with_app do |_root, app, _secret, _settings, _time|
      assets = []
      KnowledgeSDK::Dashboard::Assets::PAGES.each do |path|
        result = request(app, "GET", path)
        assert_equal 200, result.status
        assert_includes result.body, 'type="module"'
        refute_includes result.body, "__APP_MODULE__"
        assets.concat(result.body.scan(%r{(?:src|href)="(/assets/[^"]+)"}).flatten)
      end
      assets.uniq.each do |path|
        assert_match(%r{\A/assets/[a-z]+-[a-f0-9]{24}\.(js|css|svg)\z}, path)
        response = request(app, "GET", path)
        assert_equal 200, response.status
        assert_equal "no-store", response["cache-control"]
        assert_equal path.split('-').last.split('.').first, Digest::SHA256.hexdigest(response.body)[0, 24]
        refute_includes response["content-security-policy"], "unsafe-inline"
      end
      app_module = assets.find { |path| path.end_with?(".js") }
      source = request(app, "GET", app_module).body
      source.scan(%r{from "(/assets/[^"]+)"}).flatten.each { |path| assert_equal 200, request(app, "GET", path).status }
      assert_equal 404, request(app, "GET", "/assets/app.js").status
      assert_equal 400, request(app, "GET", "/assets/%2e%2e/secret").status
      assert_equal 422, request(app, "GET", "/search?q=private").status
      assert_equal 405, request(app, "POST", "/contacts").status
    end
  end

  def with_app(schema: true, grants: nil, port: 8765)
    builder = schema ? :with_schema_vault : :with_vault
    public_send(builder) do |vault|
      with_vault do |operator|
        secret = SecureRandom.urlsafe_base64(32)
        filename = File.join(operator, "secret")
        File.write(filename, secret, mode: "w", perm: 0o600)
        options = { vault: vault, timezone: "Europe/Berlin", secret_file: filename, port: port,
                    config_path: File.join(operator, "config.yml") }
        if grants
          settings_path = File.join(operator, "settings.json")
          File.write(settings_path, JSON.generate(version: 1, permissions: grants), mode: "w", perm: 0o600)
          options[:settings_file] = settings_path
        end
        settings = KnowledgeSDK::Dashboard::Settings.new(**options)
        now = Time.utc(2026, 10, 25, 12)
        app = KnowledgeSDK::Dashboard::App.new(settings, clock: -> { now })
        yield vault, app, secret, settings, ->(seconds) { now += seconds }
      ensure
        app&.close
      end
    end
  end

  def request(app, method, path, extra_headers = {}, cookie: nil, csrf: nil, body: nil, **headers)
    options = { "HTTP_HOST" => "127.0.0.1:8765" }
    options["HTTP_COOKIE"] = cookie if cookie
    if body
      options["CONTENT_TYPE"] = "application/json"
      options["HTTP_ORIGIN"] = "http://127.0.0.1:8765"
      options[:input] = JSON.generate(body)
    end
    options["HTTP_X_CSRF_TOKEN"] = csrf if csrf
    Rack::MockRequest.new(app).request(method, path, options.merge(extra_headers).merge(headers))
  end

  def login(app, secret)
    pre = request(app, "GET", "/api/v1/session")
    csrf = JSON.parse(pre.body).fetch("csrf_token")
    result = request(app, "POST", "/api/v1/session/login", cookie: pre["set-cookie"].split(";").first,
      csrf: csrf, body: { secret: secret })
    assert_equal 200, result.status, result.body
    [result["set-cookie"].split(";").first, JSON.parse(result.body).fetch("csrf_token")]
  end

  def test_authenticated_search_through_tokens_and_read_only_gateway
    with_app do |root, app, secret, _settings, _time|
      create_base_entities(root, restricted: true)
      before = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select { |p| File.file?(p) }.to_h { |p| [p, File.binread(p)] }
      assert_equal 401, request(app, "GET", "/api/v1/search?q=Ada").status
      cookie, = login(app, secret)
      result = request(app, "GET", "/api/v1/search?q=Ada", cookie: cookie)
      assert_equal 200, result.status, result.body
      data = JSON.parse(result.body)
      schema = JSON.parse(File.read(File.join(KnowledgeSDK::Dashboard::ROOT, "config", "api-response.schema.json")))
      assert AgentPlatform::SchemaValidator.new.validate!(schema, data)
      assert_equal PERSON_ID, data.dig("data", "items", 0, "id")
      assert_equal "ok", data["status"]
      refute_includes result.body, root
      refute_includes result.body, "invocation_token"
      assert_equal "no-store", result["cache-control"]
      hidden = request(app, "GET", "/api/v1/search?q=Secret+Example", cookie: cookie)
      assert_empty JSON.parse(hidden.body).dig("data", "items")
      available = request(app, "GET", "/api/v1/dashboard/availability", cookie: cookie)
      assert_equal 200, available.status, available.body
      assert_equal "unsupported", JSON.parse(available.body).dig("data", "features").find { |f| f["feature"] == "finance" }["state"]
      assert_equal 404, request(app, "POST", "/api/v1/execute", cookie: cookie, body: { capability: "kg.proposals.submit" }).status
      bridge = app.instance_variable_get(:@bridge)
      agent = app.instance_variable_get(:@sessions).fetch(cookie.split("=", 2).last)[:agent]
      ids = bridge.gateway.discover(agent: agent).map { |item| item["capability_id"] }
      assert_equal (KnowledgeSDK::Dashboard::Bridge::ALLOWED - ["kg.activity.list"]).sort, ids.sort
      assert_raises(KnowledgeSDK::Dashboard::HTTPError) { bridge.invoke("kg.proposals.submit", {}, agent) }
      forbidden = bridge.gateway.registry.reference_for("kg.proposals.submit").to_h
      submission = bridge.gateway.issue_request(invocation_token: forbidden["invocation_token"],
        arguments: { "proposal_id" => "proposal_00000000000000000000000001" })
      assert_equal "denied", bridge.gateway.execute(request: submission, agent: agent).status
      before.each { |p, bytes| assert_equal bytes, File.binread(p) }
      refute File.exist?(File.join(root, KnowledgeSDK::DATASET_PATH))
    end
  end

  def test_host_origin_csrf_input_and_logout_expiry_defenses
    with_app do |_root, app, secret, _settings, time|
      assert_equal 403, request(app, "GET", "/api/v1/session", "HTTP_HOST" => "evil.test:8765").status
      assert_equal 403, request(app, "GET", "/api/v1/session", "HTTP_ORIGIN" => "http://evil.test").status
      assert_equal 403, request(app, "POST", "/api/v1/session/login", body: { secret: secret }).status
      cookie, csrf = login(app, secret)
      assert_equal 422, request(app, "GET", "/api/v1/search?q=a&q=b", cookie: cookie).status
      assert_equal 422, request(app, "GET", "/api/v1/search?q=a&vault=bad", cookie: cookie).status
      assert_equal 422, request(app, "GET", "/api/v1/search?q=a&limit=101", cookie: cookie).status
      assert_equal 422, request(app, "GET", "/api/v1/search?q=%FF", cookie: cookie).status
      assert_equal 414, request(app, "GET", "/api/v1/search?q=#{'x' * 4100}", cookie: cookie).status
      assert_equal 403, request(app, "GET", "/api/v1/search?q=a", cookie: cookie, "HTTP_SEC_FETCH_SITE" => "cross-site").status
      assert_equal 403, request(app, "POST", "/api/v1/session/logout", cookie: cookie, csrf: "wrong", body: {}).status
      assert_equal 200, request(app, "POST", "/api/v1/session/logout", cookie: cookie, csrf: csrf, body: {}).status
      assert_equal 401, request(app, "GET", "/api/v1/search?q=a", cookie: cookie).status
      cookie, = login(app, secret)
      time.call(1801)
      assert_equal 401, request(app, "GET", "/api/v1/search?q=a", cookie: cookie).status
    end
  end

  def test_denied_features_stale_tokens_and_login_throttle
    with_app(grants: []) do |_root, app, secret, _settings, _time|
      cookie, = login(app, secret)
      unavailable = request(app, "GET", "/api/v1/search?q=synthetic", cookie: cookie)
      assert_equal 200, unavailable.status
      assert_equal "unavailable", JSON.parse(unavailable.body)["status"]
    end
    with_app do |_root, app, secret, _settings, _time|
      cookie, csrf = login(app, secret)
      bridge = app.instance_variable_get(:@bridge)
      agent = app.instance_variable_get(:@sessions).fetch(cookie.split("=", 2).last)[:agent]
      gateway = bridge.gateway
      original = gateway.method(:issue_request)
      calls = 0
      gateway.define_singleton_method(:issue_request) do |**arguments|
        calls += 1
        raise AgentPlatform::CapabilityNotFound, "synthetic stale token" if calls == 1
        original.call(**arguments)
      end
      assert bridge.invoke("kg.entities.search", { "query" => "synthetic" }, agent).success?
      assert_equal 2, calls
      gateway.define_singleton_method(:issue_request) { |**_arguments| raise AgentPlatform::CapabilityNotFound, "synthetic stale token" }
      error = assert_raises(KnowledgeSDK::Dashboard::HTTPError) { bridge.invoke("kg.entities.search", { "query" => "synthetic" }, agent) }
      assert_equal 409, error.status
      4.times { assert_equal 401, request(app, "POST", "/api/v1/session/login", cookie: cookie, csrf: csrf, body: { secret: "wrong" }).status }
      assert_equal 429, request(app, "POST", "/api/v1/session/login", cookie: cookie, csrf: csrf, body: { secret: "wrong" }).status
    end
  end

  def test_generic_and_old_dataset_browsing_does_not_initialize_storage
    with_app(schema: false) do |root, app, secret, settings, _time|
      cookie, = login(app, secret)
      assert_equal 200, request(app, "GET", "/api/v1/dashboard/availability", cookie: cookie).status
      refute File.exist?(File.join(root, ".knowledge"))
      FileUtils.mkdir_p(File.dirname(settings.dataset_path))
      db = SQLite3::Database.new(settings.dataset_path)
      db.execute("PRAGMA user_version = 1")
      db.close
      before = File.binread(settings.dataset_path)
      assert_equal 200, request(app, "GET", "/api/v1/dashboard/availability", cookie: cookie).status
      assert_equal "empty", JSON.parse(request(app, "GET", "/api/v1/search?q=synthetic", cookie: cookie).body)["status"]
      assert_equal before, File.binread(settings.dataset_path)
      assert_equal "dataset_upgrade_required", settings.reader.availability["code"]
    end
  end

  def test_job_ownership_expiry_and_revocation_and_restart
    with_app do |_root, app, secret, _settings, time|
      first, csrf = login(app, secret)
      second, = login(app, secret)
      sessions = app.instance_variable_get(:@sessions)
      agent = sessions.fetch(first.split("=", 2).last)[:agent]
      jobs = app.instance_variable_get(:@bridge).gateway.jobs
      job = jobs.submit(agent_id: agent.id, capability_id: "synthetic.read") { { secret: "never serialize" } }
      jobs.wait(job.id, agent_id: agent.id)
      owned = request(app, "GET", "/api/v1/jobs/#{job.id}", cookie: first)
      assert_equal 200, owned.status
      refute_includes owned.body, "never serialize"
      assert_equal 404, request(app, "GET", "/api/v1/jobs/#{job.id}", cookie: second).status
      time.call(601)
      assert_equal 404, request(app, "GET", "/api/v1/jobs/#{job.id}", cookie: first).status
      request(app, "POST", "/api/v1/session/logout", cookie: first, csrf: csrf, body: {})
      assert_raises(AgentPlatform::JobNotFound) { jobs.fetch(job.id) }
      app.close
      assert_equal 401, request(app, "GET", "/api/v1/search?q=a", cookie: second).status
    end
  end

  def test_real_loopback_host_search_and_raw_http_defenses
    reservation = TCPServer.new("127.0.0.1", 0)
    port = reservation.addr[1]
    reservation.close
    with_app(port: port) do |root, app, secret, settings, _time|
      create_base_entities(root)
      ready = Queue.new
      server = KnowledgeSDK::Dashboard::Server.new(app, BindAddress: "127.0.0.1", Port: port,
        StartCallback: -> { ready << true }, AccessLog: [], RequestTimeout: 2,
        Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL))
      thread = Thread.new { server.start }
      Timeout.timeout(5) { ready.pop }
      http = Net::HTTP.new("127.0.0.1", port, nil)
      http.read_timeout = 5
      challenge = http.get("/api/v1/session")
      assert_equal "200", challenge.code, challenge.body
      csrf = JSON.parse(challenge.body).fetch("csrf_token")
      headers = { "Cookie" => challenge["set-cookie"].split(";").first,
        "Origin" => settings.origin, "X-CSRF-Token" => csrf, "Content-Type" => "application/json" }
      logged_in = http.post("/api/v1/session/login", JSON.generate(secret: secret), headers)
      assert_equal "200", logged_in.code, logged_in.body
      found = http.get("/api/v1/search?q=Ada", "Cookie" => logged_in["set-cookie"].split(";").first)
      assert_equal PERSON_ID, JSON.parse(found.body).dig("data", "items", 0, "id")
      [
        ["GET /api/v1/session HTTP/1.1\r\nHost: evil.test\r\n", "403"],
        ["GET /api/v1/session HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nHost: 127.0.0.1:#{port}\r\n", "400"],
        ["GET /../ HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n", "400"],
        ["GET / HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nX-Large: #{'x' * 17000}\r\n", "431"]
      ].each do |raw, expected|
        reply = Timeout.timeout(5) do
          TCPSocket.open("127.0.0.1", port) do |socket|
            socket.write(raw + "Connection: close\r\n\r\n")
            socket.read
          end
        end
        assert_match(/\AHTTP\/1.1 #{expected} /, reply)
        refute_includes reply, secret
        refute_includes reply, root
      end
    ensure
      server&.shutdown
      thread&.join(5)
    end
  end
end
