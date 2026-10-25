# frozen_string_literal: true

require "stringio"

module KnowledgeSDK
  module Dashboard
    class App
      SECURITY_HEADERS = {
        "cache-control" => "no-store", "referrer-policy" => "no-referrer",
        "x-content-type-options" => "nosniff",
        "content-security-policy" => "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; font-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
      }.freeze

      def initialize(settings, clock: nil, logger: nil)
        @settings, @clock, @logger = settings, clock || -> { Time.now }, logger
        @assets = Assets.new
        @cursors = Cursors.new(clock: @clock)
        @bridge = Bridge.new(settings, clock: @clock)
        @sessions = Sessions.new(clock: @clock, permissions: settings.permissions,
          on_revoke: ->(id) { @bridge.gateway.jobs.remove_agent(id); @cursors.remove_agent(id) })
        @source_key = SecureRandom.random_bytes(32)
        @gate, @active = Mutex.new, 0
      end

      def close
        @sessions.clear
      end

      def call(env)
        request_id = KnowledgeGraph::IdGenerator.new(clock: @clock).generate("request")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        route = "/unknown"
        begin
          validate_transport!(env)
          path, method = env.fetch("PATH_INFO", ""), env.fetch("REQUEST_METHOD", "")
          route = known_route(path)
          response = dispatch(env, path, method, request_id)
        rescue HTTPError => error
          response = json(error.status, error.status == 200 ? envelope(request_id, "unavailable", limitation: "not_available") : envelope(request_id, "error", error: error.code))
          response[1]["retry-after"] = "60" if error.status == 429
          response[1]["allow"] = %w[/api/v1/session/login /api/v1/session/logout].include?(env["PATH_INFO"]) ? "POST" : "GET" if error.status == 405
        rescue StandardError
          response = json(500, envelope(request_id, "error", error: "internal_error"))
        end
        if @logger
          @logger.puts(JSON.generate(route: route, request_id: request_id, status: response[0],
            duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(2)))
        end
        response
      end

      private

      def known_route(path)
        return domain_template(path) if domain_template(path)
        return path if @assets.include?(path) || %w[/api/v1/session /api/v1/session/login /api/v1/session/logout /api/v1/search /api/v1/dashboard/availability].include?(path)
        path.match?(%r{\A/api/v1/jobs/[^/]+\z}) ? "/api/v1/jobs/:id" : "/unknown"
      end

      def validate_transport!(env)
        host = env["HTTP_HOST"]
        forbidden = env.keys.any? { |key| key.start_with?("HTTP_X_FORWARDED") || key == "HTTP_FORWARDED" }
        raise HTTPError.new(403, "request_forbidden") if host != "127.0.0.1:#{@settings.port}" || forbidden
        origin = env["HTTP_ORIGIN"]
        if (origin && origin != @settings.origin) || env["HTTP_SEC_FETCH_SITE"] == "cross-site"
          raise HTTPError.new(403, "request_forbidden")
        end
        raw = env["REQUEST_URI"].to_s
        raise HTTPError.new(403, "request_forbidden") if raw.match?(%r{\Ahttps?://}i)
        query, path = env.fetch("QUERY_STRING", ""), env.fetch("PATH_INFO", "")
        raise HTTPError.new(414, "request_too_large") if path.bytesize + query.bytesize > 8192 || query.bytesize > 4096
        headers = env.select { |key, _value| key.start_with?("HTTP_") }.sum { |key, value| key.bytesize + value.to_s.bytesize }
        raise HTTPError.new(431, "request_too_large") if headers > 16_384
        raise HTTPError.new(400, "invalid_request") unless path.valid_encoding? && query.valid_encoding?
        if path.include?("\0") || path.split("/").any? { |part| part == "." || part == ".." } || path.include?("\\") || path.include?("%")
          raise HTTPError.new(400, "invalid_request")
        end
      end

      def dispatch(env, path, method, request_id)
        if @assets.include?(path)
          raise HTTPError.new(405, "method_not_allowed") unless method == "GET"
          raise HTTPError.new(422, "invalid_arguments") unless env.fetch("QUERY_STRING", "").empty?
          type, content = @assets.fetch(path)
          return [200, SECURITY_HEADERS.merge("content-type" => type), [content]]
        end
        raise HTTPError.new(404, "not_found") if known_route(path) == "/unknown"
        expected = %w[/api/v1/session/login /api/v1/session/logout].include?(path) ? "POST" : "GET"
        raise HTTPError.new(405, "method_not_allowed") unless method == expected
        if method == "GET" && (env.fetch("CONTENT_LENGTH", "0").to_i > 0 || env["HTTP_TRANSFER_ENCODING"])
          raise HTTPError.new(400, "invalid_request")
        end
        session = @sessions.fetch(cookie_id(env))
        if path == "/api/v1/session"
          parameters(env, [])
          session ||= @sessions.create
          return session_response(session)
        end
        if method == "POST"
          parameters(env, [])
          validate_csrf!(env, session)
          body = login_body(env)
          if path.end_with?("/login")
            raise HTTPError.new(422, "invalid_arguments") unless body.keys == ["secret"] && body["secret"].is_a?(String)
            @sessions.throttle!("login:global", 20)
            # Loopback has one client address; new cookies must not bypass throttling.
            @sessions.throttle!("login:loopback", 5)
            digest = Digest::SHA256.digest(body["secret"])
            raise HTTPError.new(401, "authentication_required") unless secure_equal?(digest, @settings.secret_digest)
            replacement = @sessions.create(authenticated: true)
            @sessions.revoke(session[:id])
            return session_response(replacement)
          end
          raise HTTPError.new(401, "authentication_required") unless session[:authenticated]
          raise HTTPError.new(422, "invalid_arguments") unless body.empty?
          @sessions.revoke(session[:id])
          return json(200, { authenticated: false }, "set-cookie" => cookie("", 0))
        end
        raise HTTPError.new(401, "authentication_required") unless session && session[:authenticated]
        @sessions.throttle!("data:#{session[:id]}", 120)
        @sessions.throttle!("data:global", 240)
        @sessions.touch(session) unless env["HTTP_X_DASHBOARD_POLL"] == "1"
        response = admit do
          case path
          when "/api/v1/search" then search(env, session, request_id)
          when "/api/v1/dashboard/availability"
            parameters(env, [])
            result = invoke("kg.dashboard.availability", {}, session)
            json(200, envelope(request_id, "ok", data: result.payload))
          else
            if domain_template(path)
              domain_read(env, session, request_id)
            else
              parameters(env, [])
              owned_job(path, session, request_id)
            end
          end
        end
        current = @sessions.fetch(session[:id])
        response[1]["set-cookie"] = cookie(current[:id], [(@sessions.expires_at(current) - @clock.call).to_i, 0].max) if current
        response[1]["x-dashboard-session-expires-at"] = @sessions.expires_at(current).getutc.iso8601 if current
        response
      end

      def search(env, session, request_id)
        params = parameters(env, %w[q entity_type limit])
        query = params.fetch("q", "").strip
        unless query.length.between?(1, 200) && query.bytesize <= 800
          raise HTTPError.new(422, "invalid_arguments")
        end
        limit_text = params.fetch("limit", "25")
        raise HTTPError.new(422, "invalid_arguments") unless limit_text.match?(/\A[0-9]{1,3}\z/) && limit_text.to_i.between?(1, 100)
        args = { "query" => query, "limit" => limit_text.to_i }
        args["entity_type"] = params["entity_type"] if params["entity_type"]
        result = nil
        consistent = false
        Timeout.timeout(5) do
          previous = invoke("kg.entities.search", args, session)
          2.times do
            current = invoke("kg.entities.search", args, session)
            if current.payload == previous.payload
              result, consistent = current, true
              break
            end
            previous = current
          end
        end
        unless consistent
          return json(200, envelope(request_id, "partial", data: { items: [], page: { returned: 0, next_cursor: nil } },
            limitation: "source_changed"))
        end
        fields = %w[id type name aliases record_status signals]
        items = result.payload.fetch("matches").map { |item| item.select { |key, _value| fields.include?(key) } }
        version = OpenSSL::HMAC.hexdigest("SHA256", @source_key, JSON.generate([session[:agent].permissions, args, items]))
        bounded = items.length == limit_text.to_i
        json(200, envelope(request_id, bounded ? "partial" : (items.empty? ? "empty" : "ok"),
          data: { items: items, page: { returned: items.length, next_cursor: nil } },
          limitation: bounded ? "result_bound_reached" : nil,
          sources: [{ kind: "graph", version: "sv_#{version}", observed_at: nil }]))
      rescue ::Timeout::Error
        raise HTTPError.new(504, "timeout")
      end

      def invoke(selector, arguments, session)
        @bridge.invoke(selector, arguments, session[:agent]).tap do |response|
          unless response.success?
            code = response.errors.first && response.errors.first["code"]
            status = { "InvalidArguments" => 422, "PolicyDenied" => 404, "CapabilityNotFound" => 404, "Timeout" => 504 }.fetch(code, 500)
            message = { 422 => "invalid_arguments", 404 => "not_found", 504 => "timeout", 500 => "internal_error" }.fetch(status)
            raise HTTPError.new(status, message)
          end
        end
      end

      def owned_job(path, session, request_id)
        id = path.split("/").last
        raise HTTPError.new(422, "invalid_arguments") unless id.match?(/\Ajob_[0-9A-HJKMNP-TV-Z]{26}\z/)
        job = @bridge.gateway.job_status(job_id: id, agent: session[:agent])
        # P1 admits synchronous contracts only. Do not expose an unregistered/raw result.
        data = { job_id: id, state: job.fetch("status"), progress: job.fetch("progress"), result: nil }
        json(200, envelope(request_id, "ok", data: data))
      rescue AgentPlatform::PolicyDenied, AgentPlatform::JobNotFound
        raise HTTPError.new(404, "not_found")
      end

      def admit
        accepted = @gate.synchronize { @active < 4 && ((@active += 1) > 0) }
        raise HTTPError.new(429, "rate_limited") unless accepted
        begin
          yield
        ensure
          @gate.synchronize { @active -= 1 }
        end
      end

      def parameters(env, allowed)
        source = env.fetch("QUERY_STRING", "")
        raise HTTPError.new(400, "invalid_request") if source.match?(/%(?![0-9a-f]{2})/i)
        pairs = URI.decode_www_form(source, Encoding::ASCII_8BIT).map do |key, value|
          [key.force_encoding(Encoding::UTF_8), value.force_encoding(Encoding::UTF_8)]
        end
        keys = pairs.map(&:first)
        unless (keys - allowed).empty? && keys.uniq.length == keys.length && pairs.flatten.all? { |value| value.valid_encoding? && !value.include?("\0") }
          raise HTTPError.new(422, "invalid_arguments")
        end
        pairs.to_h
      rescue ArgumentError
        raise HTTPError.new(400, "invalid_request")
      end

      def login_body(env)
        raise HTTPError.new(415, "unsupported_media_type") unless env["CONTENT_TYPE"].to_s.split(";").first == "application/json"
        raise HTTPError.new(400, "invalid_request") if env["HTTP_TRANSFER_ENCODING"]
        raise HTTPError.new(413, "request_too_large") if env.fetch("CONTENT_LENGTH", "0").to_i > 4096
        text = env.fetch("rack.input", StringIO.new).read(4097)
        raise HTTPError.new(413, "request_too_large") if text.bytesize > 4096
        body = JSON.parse(text)
        raise HTTPError.new(422, "invalid_arguments") unless body.is_a?(Hash)
        body
      rescue JSON::ParserError
        raise HTTPError.new(400, "invalid_request")
      end

      def validate_csrf!(env, session)
        unless session && env["HTTP_ORIGIN"] == @settings.origin && secure_equal?(env["HTTP_X_CSRF_TOKEN"].to_s, session[:csrf_token])
          raise HTTPError.new(403, "request_forbidden")
        end
      end

      def secure_equal?(first, second)
        Rack::Utils.secure_compare(first, second)
      end

      def cookie_id(env)
        pairs = env.fetch("HTTP_COOKIE", "").split(";").map { |part| part.strip.split("=", 2) }
        values = pairs.select { |name, _value| name == Sessions::COOKIE }.map(&:last)
        values.length == 1 ? values.first : nil
      end

      def session_response(session)
        value = { authenticated: session[:authenticated], csrf_token: session[:csrf_token] }
        if session[:authenticated]
          value.merge!(expires_at: @sessions.expires_at(session).utc.iso8601,
            display_label: @settings.display_label, timezone: @settings.timezone,
            tzdata_version: TZInfo::Data::Version::TZDATA)
        end
        json(200, value, "set-cookie" => cookie(session[:id], [(@sessions.expires_at(session) - @clock.call).to_i, 0].max))
      end

      def cookie(id, max_age)
        "#{Sessions::COOKIE}=#{id}; Path=/; HttpOnly; SameSite=Strict; Max-Age=#{max_age}"
      end

      def envelope(id, status, data: nil, error: nil, sources: [], limitation: nil)
        warning = limitation && { code: limitation, message: limitation.tr("_", " ") }
        { contract_version: "1.0.0", request_id: id, status: status, data: data,
          warnings: warning ? [warning] : [], scope: { owner_id: nil, subject_id: nil, account_id: nil },
          window: { from: nil, to: nil, bounds: nil, as_of: nil, timezone: @settings.timezone },
          computed_at: @clock.call.getutc.iso8601(6), sources: sources,
          completeness: { complete: %w[ok empty].include?(status), limitations: warning ? [warning] : [] }, evidence: [],
          error: error && { code: error, message: error.tr("_", " ") } }
      end

      def json(status, body, extra = {})
        text = JSON.generate(body)
        raise HTTPError.new(503, "service_unavailable") if text.bytesize > 1_048_576
        [status, SECURITY_HEADERS.merge("content-type" => "application/json; charset=utf-8").merge(extra), [text]]
      end
    end
  end
end
