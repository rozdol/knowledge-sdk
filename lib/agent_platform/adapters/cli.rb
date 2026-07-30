# frozen_string_literal: true

require "json"

module AgentPlatform
  module Adapters
    class CLI
      def initialize(gateway:, argv:, out:, err:, agent:)
        @gateway = gateway
        @argv = argv.dup
        @out = out
        @err = err
        @agent = agent
      end

      def run
        command = @argv.shift
        case command
        when "capabilities" then capabilities
        when "execute" then execute
        when "explain" then explain
        when "policy" then policy
        when "job" then job
        when "help", "--help", "-h", nil then help
        else raise InvalidRequest, "unknown gateway command"
        end
      rescue JSON::ParserError, KeyError, ArgumentError, AgentPlatform::Error => error
        @err.puts(JSON.generate(error: error.message, error_class: error.class.name))
        2
      end

      private

      def capabilities
        @out.puts(JSON.pretty_generate(capabilities: @gateway.discover(agent: @agent)))
        0
      end

      def execute
        selector = @argv.shift || raise(InvalidRequest, "gateway execute expects CAPABILITY_ID[@VERSION]")
        arguments = @argv.shift || "{}"
        raise InvalidRequest, "unexpected gateway execute arguments" unless @argv.empty?

        contract = select_contract(selector)
        request = @gateway.issue_request(
          invocation_token: contract.fetch("invocation_token"), arguments: JSON.parse(arguments)
        )
        response = @gateway.execute(request: request, agent: @agent)
        @out.puts(JSON.pretty_generate(response.to_h))
        response.success? ? 0 : 1
      end

      def explain
        trace_id = @argv.shift || raise(InvalidRequest, "gateway explain expects TRACE_ID")
        @out.puts(JSON.pretty_generate(@gateway.explain_trace(trace_id: trace_id, agent: @agent)))
        0
      end

      def policy
        action = @argv.shift
        raise InvalidRequest, "gateway policy expects check" unless action == "check"
        selector = @argv.shift || raise(InvalidRequest, "gateway policy check expects CAPABILITY_ID[@VERSION]")
        arguments = JSON.parse(@argv.shift || "{}")
        contract = select_contract(selector)
        decision = @gateway.policy_check(
          invocation_token: contract.fetch("invocation_token"), arguments: arguments, agent: @agent
        )
        @out.puts(JSON.pretty_generate(decision))
        decision.fetch(:allowed) ? 0 : 1
      end

      def job
        job_id = @argv.shift || raise(InvalidRequest, "gateway job expects JOB_ID")
        wait_ms = @argv.shift
        value = @gateway.job_status(job_id: job_id, agent: @agent, wait_ms: wait_ms && Integer(wait_ms))
        @out.puts(JSON.pretty_generate(value))
        0
      end

      def select_contract(selector)
        id, version = selector.split("@", 2)
        candidates = @gateway.discover(agent: @agent).select { |item| item.fetch("capability_id") == id }
        candidates = candidates.select { |item| item.fetch("version") == version } if version
        raise CapabilityNotFound, "capability is unavailable to this agent" if candidates.empty?

        candidates.max_by { |item| ManifestCompatibility.version_parts(item.fetch("version")) }
      end

      def help
        @out.puts("Usage: kg gateway capabilities")
        @out.puts("       kg gateway execute CAPABILITY_ID[@VERSION] [ARGUMENTS_JSON]")
        @out.puts("       kg gateway policy check CAPABILITY_ID[@VERSION] [ARGUMENTS_JSON]")
        @out.puts("       kg gateway explain TRACE_ID")
        @out.puts("       kg gateway job JOB_ID [WAIT_MS]")
        0
      end
    end
  end
end
