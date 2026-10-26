# frozen_string_literal: true
require_relative "app_test"
require_relative "../../../test/agent_platform/health_fixture"

class DashboardHealthRoutesTest < DashboardAppTest
  include HealthReadFixture

  def self.runnable_methods
    super.grep(/\Atest_p5_/)
  end

  def test_p5_dates_explicit_subject_cursor_drift_and_nonmutation
    with_app(grants: %w[graph:read dataset:read health:read]) do |root, app, secret, settings, _time|
      writer = HealthReadFixture.build(root)
      before = HealthReadFixture.logical(root)
      cookie, = login(app, secret)
      scopes = request(app, "GET", "/api/v1/health/labs?scopes=true", cookie: cookie)
      assert_equal [SUBJECT, OTHER], JSON.parse(scopes.body).dig("data", "subjects").map { |item| item["id"] }
      base = "/api/v1/health/labs?subject_id=#{SUBJECT}"
      response = request(app, "GET", base + "&limit=2", cookie: cookie)
      body = JSON.parse(response.body)
      assert_equal 200, response.status, response.body
      assert_equal SUBJECT, body.dig("scope", "subject_id")
      assert_equal "2026-09-26", body.dig("window", "from")
      assert_equal "2026-10-25", body.dig("window", "to")
      assert_equal "inclusive_dates", body.dig("window", "bounds")
      assert_equal "Europe/Berlin", body.dig("window", "timezone")
      cursor = body.dig("data", "page", "next_cursor")
      assert_match(/\A[A-Za-z0-9_-]{43}\z/, cursor)
      assert_equal 200, request(app, "GET", base + "&limit=2&cursor=#{cursor}", cookie: cookie).status
      assert_equal 409, request(app, "GET", base + "&limit=3&cursor=#{cursor}", cookie: cookie).status
      single = request(app, "GET", base + "&from=2026-10-25&to=2026-10-25", cookie: cookie)
      assert_equal 4, JSON.parse(single.body).dig("data", "items").length
      series = request(app, "GET", "/api/v1/health/labs/series?subject_id=#{SUBJECT}&analyte=#{URI.encode_www_form_component(ANALYTE)}", cookie: cookie)
      assert_equal 6, JSON.parse(series.body).dig("data", "series").length
      ["/api/v1/health/labs", "/api/v1/health/labs?scopes=true&limit=2", "/api/v1/health/labs?scopes=yes",
        base + "&from=2026-01-01", base + "&from=2020-01-01&to=2026-01-01", base + "&from=2026-10-25T00:00:00Z&to=2026-10-25", base + "&method=x"].each do |path|
        assert_equal 422, request(app, "GET", path, cookie: cookie).status, path
      end
      assert_equal before, HealthReadFixture.logical(root)
      hidden = writer.query("clinical_samples").find { |row| row["subject_id"] == HIDDEN }
      writer.update("clinical_samples", hidden["row_id"], { value: 8888 })
      assert_equal 200, request(app, "GET", base + "&limit=2&cursor=#{cursor}", cookie: cookie).status
      visible = writer.query("clinical_samples").find { |row| row["value"] == 12 }
      writer.update("clinical_samples", visible["row_id"], { value: 13 })
      assert_equal 409, request(app, "GET", base + "&limit=2&cursor=#{cursor}", cookie: cookie).status
      availability = JSON.parse(request(app, "GET", "/api/v1/dashboard/availability", cookie: cookie).body)
      assert_equal "available", availability.dig("data", "features").find { |f| f["feature"] == "medical" }["state"]
      db = SQLite3::Database.new(settings.dataset_path); db.execute("PRAGMA user_version = 1"); db.close
      bytes = File.binread(settings.dataset_path)
      assert_includes request(app, "GET", base, cookie: cookie).body, "dataset_upgrade_required"
      assert_equal bytes, File.binread(settings.dataset_path)
    end
    with_app do |root, app, secret, _settings, _time|
      cookie, = login(app, secret)
      assert_equal "unavailable", JSON.parse(request(app, "GET", "/api/v1/health/labs?scopes=true", cookie: cookie).body)["status"]
      refute File.exist?(File.join(root, ".knowledge"))
    end
  end
end
