# frozen_string_literal: true

module KnowledgeSDK
  module Dashboard
    class Bridge
      ALLOWED = %w[kg.entities.search kg.dashboard.availability kg.contacts.list kg.contacts.get
        kg.contacts.top kg.contacts.relations kg.captures.list kg.captures.get kg.activity.list
        kg.finance.scopes kg.finance.net_worth kg.finance.positions kg.finance.liabilities
        kg.finance.transactions kg.finance.pnl kg.health.labs kg.health.lab_series].freeze
      attr_reader :gateway

      def initialize(settings, clock:)
        @settings = settings
        jobs = AgentPlatform::JobManager.new(clock: clock, limit: 100, per_agent_limit: 20, ttl_seconds: 600)
        @gateway = AgentPlatform.build(
          vault_root: settings.vault, environment: "read_only", read_only_services: true,
          dataset_engine_factory: -> { settings.reader }, jobs: jobs, clock: clock,
          telemetry: AgentPlatform::TelemetryRecorder.new(clock: clock, limit: 1000, ttl_seconds: 600)
        )
        @gateway.plugin_registrar.load_manifests(
          File.join(ROOT, "config", "dashboard.json"),
          handlers: { "kg.dashboard.availability" => method(:availability) }
        )
      end

      def invoke(selector, arguments, agent)
        raise HTTPError.new(404, "not_found") unless ALLOWED.include?(selector)

        2.times do
          contract = gateway.discover(agent: agent).reverse.find { |item| item["capability_id"] == selector }
          raise HTTPError.new(200, "not_available") unless contract
          unless contract.dig("execution", "effects") == "read_only" && contract.dig("policy", "approval") == "none" &&
                 contract.dig("execution", "mode") == "synchronous" && contract.dig("execution", "timeout_ms") <= 30_000
            raise HTTPError.new(403, "request_forbidden")
          end
          begin
            request = gateway.issue_request(invocation_token: contract.fetch("invocation_token"), arguments: arguments)
            response = gateway.execute(request: request, agent: agent)
            return response unless response.errors.any? { |error| error["code"] == "CapabilityNotFound" }
          rescue AgentPlatform::CapabilityNotFound
            # Manifest changed between discovery and issue; rediscover once.
          end
        end
        raise HTTPError.new(409, "context_changed")
      end

      private

      def availability(_arguments, context)
        schemas = KnowledgeGraph::SchemaRegistry.new(vault_root: @settings.vault)
        features = %w[search contacts memory finance medical automation calendar learning hermes os].map do |feature|
          state = case feature
                  when "search" then schemas.keys.empty? ? "empty" : "available"
                  when "contacts"
                    schemas.key?("person") && schemas.fetch("person").name_required? &&
                      (%w[tier sensitivity data_origin] - schemas.fetch("person").required_fields).empty? ? "available" : "unsupported"
                  when "memory" then context.agent.permits?("capture:read") || context.agent.permits?("activity:read") ? "available" : "not_available"
                  when "finance"
                    if !%w[finance:read graph:read dataset:read].all? { |grant| context.agent.permits?(grant) }
                      "not_available"
                    else
                      response = invoke("kg.finance.scopes", {}, context.agent)
                      if !response.success? || response.payload["status"] == "unavailable"
                        "not_available"
                      elsif response.payload["status"] == "empty"
                        "empty"
                      else
                        storage = @settings.reader.availability
                        storage["status"] == "ready" ? "available" : storage["code"] == "dataset_upgrade_required" ? "upgrade_required" : "not_available"
                      end
                    end
                  when "medical"
                    if !%w[health:read graph:read dataset:read].all? { |grant| context.agent.permits?(grant) }
                      "not_available"
                    else
                      response = invoke("kg.health.labs", { "scopes" => true }, context.agent)
                      if !response.success? || response.payload["status"] == "unavailable"
                        response.payload.fetch("limitations", []).include?("dataset_upgrade_required") ? "upgrade_required" : "not_available"
                      elsif response.payload["status"] == "empty"
                        "empty"
                      else
                        "available"
                      end
                    end
                  else "unsupported"
                  end
          { "feature" => feature, "state" => state, "reason" => state == "unsupported" ? "not_implemented" : nil }
        end
        AgentPlatform::HandlerResult.new(payload: { "features" => features }, why: "Only implemented, policy-visible read features are advertised.")
      end
    end
  end
end
