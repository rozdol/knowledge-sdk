# frozen_string_literal: true

module AgentPlatform
  module Adapters
    class MCP
      def initialize(gateway)
        @gateway = gateway
      end

      def tools(agent:, session_id: nil)
        @gateway.discover(agent: agent, session_id: session_id).map do |contract|
          {
            name: tool_name(contract.fetch("capability_id"), contract.fetch("version")),
            description: contract.fetch("description"),
            inputSchema: contract.fetch("input_schema"),
            outputSchema: contract.fetch("output_schema"),
            annotations: {
              readOnlyHint: contract.fetch("execution").fetch("effects") == "read_only",
              idempotentHint: contract.fetch("execution").fetch("idempotent")
            },
            _meta: {
              capability_id: contract.fetch("capability_id"),
              capability_version: contract.fetch("version"),
              invocation_token: contract.fetch("invocation_token"),
              manifest_digest: contract.fetch("manifest_digest")
            }
          }
        end
      end

      def call_tool(name:, arguments:, agent:, session_id: nil, trace_id: nil)
        tool = tools(agent: agent, session_id: session_id).find { |item| item.fetch(:name) == name.to_s }
        raise CapabilityNotFound, "MCP tool is not present in policy-filtered discovery" unless tool

        token = tool.fetch(:_meta).fetch(:invocation_token)
        request = @gateway.issue_request(
          invocation_token: token, arguments: arguments,
          session_id: session_id, trace_id: trace_id
        )
        response = @gateway.execute(request: request, agent: agent)
        {
          isError: !response.success?,
          structuredContent: response.to_h,
          content: [{ type: "text", text: Value.canonical_json(response.to_h) }]
        }
      end

      private

      def tool_name(capability_id, version)
        "#{capability_id.tr('.', '_')}__v#{version.split('.').first}"
      end
    end
  end
end
