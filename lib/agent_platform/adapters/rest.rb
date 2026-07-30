# frozen_string_literal: true

module AgentPlatform
  module Adapters
    class REST
      def initialize(gateway)
        @gateway = gateway
      end

      def capabilities(agent:, session_id: nil)
        { status: 200, body: { capabilities: @gateway.discover(agent: agent, session_id: session_id) } }
      end

      def execute(body:, agent:)
        payload = Value.mutable(body)
        request = @gateway.issue_request(
          invocation_token: payload.fetch("invocation_token"),
          arguments: payload.fetch("arguments", {}), session_id: payload["session_id"],
          trace_id: payload["trace_id"]
        )
        response = @gateway.execute(request: request, agent: agent)
        status = response.success? ? (response.status == "accepted" ? 202 : 200) : error_status(response.status)
        { status: status, body: response.to_h }
      rescue KeyError => error
        { status: 400, body: { status: "invalid_request", error: error.message } }
      end

      private

      def error_status(status)
        { "denied" => 403, "approval_required" => 409, "invalid_request" => 422 }.fetch(status, 500)
      end
    end
  end
end
