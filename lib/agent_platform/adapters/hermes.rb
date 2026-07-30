# frozen_string_literal: true

module AgentPlatform
  module Adapters
    class Hermes
      def initialize(gateway)
        @gateway = gateway
      end

      def capabilities(agent:, session_id: nil)
        @gateway.discover(agent: agent, session_id: session_id)
      end

      def execute(invocation_token:, arguments:, agent:, session_id: nil, trace_id: nil)
        request = @gateway.issue_request(
          invocation_token: invocation_token, arguments: arguments,
          session_id: session_id, trace_id: trace_id
        )
        @gateway.execute(request: request, agent: agent).to_h
      end

      def job(job_id:, agent:, wait_ms: nil)
        @gateway.job_status(job_id: job_id, agent: agent, wait_ms: wait_ms)
      end
    end
  end
end
