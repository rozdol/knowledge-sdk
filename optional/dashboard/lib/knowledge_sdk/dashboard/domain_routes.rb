# frozen_string_literal: true

module KnowledgeSDK
  module Dashboard
    class App
      DOMAIN_ROUTES = {
        "/api/v1/contacts" => ["kg.contacts.list", %w[q limit cursor]],
        "/api/v1/contacts/top" => ["kg.contacts.top", %w[as_of]],
        "/api/v1/contacts/:id" => ["kg.contacts.get", []],
        "/api/v1/contacts/:id/relations" => ["kg.contacts.relations", %w[depth as_of]],
        "/api/v1/captures" => ["kg.captures.list", %w[q kind status from to limit cursor]],
        "/api/v1/captures/:id" => ["kg.captures.get", []],
        "/api/v1/activity" => ["kg.activity.list", %w[q from to limit cursor]]
      }.freeze

      private

      def domain_template(path)
        return path if DOMAIN_ROUTES.key?(path)
        return "/api/v1/contacts/:id/relations" if path.match?(%r{\A/api/v1/contacts/[^/]+/relations\z})
        return "/api/v1/contacts/:id" if path.match?(%r{\A/api/v1/contacts/[^/]+\z})
        return "/api/v1/captures/:id" if path.match?(%r{\A/api/v1/captures/[^/]+\z})
        nil
      end

      def domain_read(env, session, request_id)
        path = env.fetch("PATH_INFO")
        template = domain_template(path)
        selector, allowed = DOMAIN_ROUTES.fetch(template)
        params = parameters(env, allowed)
        arguments = {}
        params.each do |key, value|
          next if key == "cursor"
          raise HTTPError.new(422, "invalid_arguments") if value.length > 200 || value.bytesize > 800
          case key
          when "limit", "depth"
            max = key == "depth" ? 2 : 100
            raise HTTPError.new(422, "invalid_arguments") unless value.match?(/\A[0-9]{1,3}\z/) && value.to_i.between?(1, max)
            arguments[key] = value.to_i
          when "q"
            raise HTTPError.new(422, "invalid_arguments") if value.strip.empty?
            arguments["query"] = value.strip
          else arguments[key] = value
          end
        end
        if template.include?(":id")
          id = path.split("/")[4]
          prefix = template.include?("captures") ? "capture" : "person"
          raise HTTPError.new(422, "invalid_arguments") unless id.match?(/\A#{prefix}_[0-9A-HJKMNP-TV-Z]{26}\z/)
          arguments[prefix == "capture" ? "capture_id" : "entity_id"] = id
        end
        now = TZInfo::Timezone.get(@settings.timezone).to_local(@clock.call.getutc)
        arguments["as_of"] ||= now.to_date.iso8601 if selector.start_with?("kg.contacts.") && selector != "kg.contacts.list"
        # Activity defaults follow successive configured-zone calendar midnights.
        if selector == "kg.activity.list" && !params["from"] && !params["to"]
          zone = TZInfo::Timezone.get(@settings.timezone)
          finish = now.to_date + 1
          start = finish - 30
          arguments["from"] = zone.local_time(start.year, start.month, start.day).getutc.iso8601
          arguments["to"] = zone.local_time(finish.year, finish.month, finish.day).getutc.iso8601
        end
        if params["from"] || params["to"]
          raise HTTPError.new(422, "invalid_arguments") unless params["from"] && params["to"]
          values = %w[from to].map do |key|
            value = params.fetch(key)
            raise HTTPError.new(422, "invalid_arguments") unless value.match?(/\A\d{4}-\d\d-\d\dT.*(?:Z|[+-]\d\d:\d\d)\z/)
            Time.iso8601(value)
          end
          first, last = values.map { |time| TZInfo::Timezone.get(@settings.timezone).to_local(time.getutc).to_date }
          raise HTTPError.new(422, "invalid_arguments") unless values[1] > values[0] && last - first <= 366
          arguments["from"], arguments["to"] = values.map { |time| time.getutc.iso8601(6) }
        end
        arguments["limit"] ||= 25 if allowed.include?("limit")
        binding = params["cursor"] && @cursors.fetch(params["cursor"], owner: session[:agent].id, selector: selector, filters: arguments)
        payload = nil
        capability_version = nil
        seconds = selector.match?(/\.(?:get|top|relations)\z/) ? 10 : 5
        Timeout.timeout(seconds) do
          2.times do
            before_response = invoke(selector, arguments, session)
            before = before_response.payload
            identity = [before_response.capability_version, before["source_version"]]
            if binding && identity != binding[:version]
              raise HTTPError.new(409, "context_changed")
            end
            args = binding ? arguments.merge("after" => binding[:after]) : arguments
            current_response = invoke(selector, args, session)
            current = current_response.payload
            if identity == [current_response.capability_version, current["source_version"]]
              payload, capability_version = current, current_response.capability_version
              break
            end
          end
        end
        return json(200, envelope(request_id, "partial", limitation: "source_changed")) unless payload
        data = AgentPlatform::Value.mutable(payload["data"])
        if data && data["page"]
          after = data["page"].delete("after")
          data["page"]["next_cursor"] = after && @cursors.issue(owner: session[:agent].id, selector: selector,
            filters: arguments, version: [capability_version, payload.fetch("source_version")].freeze, after: after)
        end
        version = OpenSSL::HMAC.hexdigest("SHA256", @source_key, JSON.generate([session[:agent].permissions, selector, capability_version, arguments, payload["source_version"]]))
        body = envelope(request_id, payload.fetch("status"), data: data,
          sources: [{ kind: selector.split('.')[1] == "contacts" ? "graph" : selector.split('.')[1], version: "sv_#{version}", observed_at: nil }])
        warnings = payload.fetch("limitations").map { |code| { code: code, message: code.tr("_", " ") } }
        body[:warnings] = warnings
        body[:completeness][:limitations] = warnings
        body[:evidence] = payload.fetch("evidence")
        body[:window].merge!(from: arguments["from"], to: arguments["to"], as_of: arguments["as_of"],
          bounds: arguments["from"] ? "half_open_instants" : arguments["as_of"] ? "inclusive_dates" : nil)
        json(200, body)
      rescue ArgumentError, TZInfo::PeriodNotFound, TZInfo::AmbiguousTime
        raise HTTPError.new(422, "invalid_arguments")
      rescue ::Timeout::Error
        raise HTTPError.new(504, "timeout")
      end
    end
  end
end
