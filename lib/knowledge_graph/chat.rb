# frozen_string_literal: true

module KnowledgeGraph
  class ChatError < Error; end

  class ChatIntentResolver
    Decision = Struct.new(:route, :reason, :capability, keyword_init: true)

    PLAN_REQUEST = /\A(?:please\s+)?(?:(?:make|create|build|draft|develop|prepare)\b.*\bplan\b|plan\b)/i.freeze
    SEARCH_REQUEST = /\A(?:who|what|where|when|which|why|how|does|do|did|is|are|was|were|can|could|would|tell\s+me|show\s+me|find)\b/i.freeze
    UNSUPPORTED_ACTION = /\A(?:please\s+)?(?:add|archive|approve|call|change|delete|edit|email|execute|merge|remove|rename|schedule|send|submit|update)\b/i.freeze

    def resolve(text)
      source = text.to_s.strip
      raise ChatError, "chat text is empty" if source.empty?

      return decision("proposal", "request concerns existing proposals", "kg.proposals.status") if proposal_request?(source)
      return decision("plan", "explicit request to create a plan", "kg.planning.plan") if PLAN_REQUEST.match?(source)
      if SEARCH_REQUEST.match?(source) || source.end_with?("?")
        return decision("search", "informational question about existing knowledge", "kg.graph.query")
      end
      if UNSUPPORTED_ACTION.match?(source)
        return decision("clarification", "requested action is not safely covered by a chat route", nil)
      end
      if source.split(/\s+/).length < 3
        return decision("clarification", "message is too short to distinguish an observation from a query", nil)
      end

      decision("observe", "declarative message suitable for the existing observation pipeline", "kg.observe")
    end

    private

    def proposal_request?(source)
      return true if source.match?(/\bproposal_[0-9A-HJKMNP-TV-Z]{26}\b/)
      return false unless source.match?(/\bproposals?\b/i)

      source.end_with?("?") || source.match?(
        /\A(?:please\s+)?(?:show|list|inspect|check|review|open|find|create|make)\b|\bpending\b|\bstatus\b/i
      )
    end

    def decision(route, reason, capability)
      Decision.new(route: route, reason: reason, capability: capability).freeze
    end
  end

  class ChatRouter
    PROPOSAL_ID = /\bproposal_[0-9A-HJKMNP-TV-Z]{26}\b/.freeze
    ENTITY_QUERY_PATTERNS = [
      /\Awho\s+is\s+(.+?)\??\z/i,
      /\Awhere\s+does\s+(.+?)\s+work\??\z/i,
      /\Awho\s+works\s+at\s+(.+?)\??\z/i,
      /\Awhat\s+do\s+(?:you|we)\s+know\s+about\s+(.+?)\??\z/i,
      /\Atell\s+me\s+about\s+(.+?)\??\z/i,
      /\A(?:find|show\s+me)\s+(.+?)\??\z/i
    ].freeze

    def initialize(gateway:, actor_id: nil, resolver: ChatIntentResolver.new)
      @gateway = gateway
      @resolver = resolver
      @agent = AgentPlatform::AgentIdentity.new(
        id: actor_id.to_s.empty? ? "kg-chat-cli" : actor_id.to_s,
        permissions: %w[graph:read dataset:read intelligence:read planning:read proposal:read],
        roles: ["chat_client"],
        attributes: {
          "autonomous_execution" => false,
          "allowed_capabilities" => %w[
            kg.entities.search kg.graph.query kg.datasets.query kg.planning.plan kg.proposals.status
          ],
          "denied_capabilities" => ["kg.proposals.submit"]
        }
      )
    end

    def route(text, explain: false)
      decision = @resolver.resolve(text)
      response, capability = case decision.route
                             when "observe" then observation_response(decision) { yield }
                             when "search" then search_response(text, decision)
                             when "plan" then capability_response(
                               decision, "kg.planning.plan",
                               "goal" => { "description" => text, "goal_type" => "generic" }
                             )
                             when "proposal" then proposal_response(text, decision)
                             when "clarification" then [intent_clarification, nil]
                             else raise ChatError, "unsupported chat route #{decision.route.inspect}"
                             end
      if explain
        response["explain"] = {
          "reason" => decision.reason,
          "capability" => capability
        }
      end
      response
    end

    private

    def observation_response(decision)
      result = yield
      unless result.is_a?(Hash)
        raise ChatError, "observation route returned an invalid response"
      end
      if result["status"] == "error"
        return [{ "status" => "error", "route" => decision.route, "error" => result.fetch("error") }, "kg.observe"]
      end
      if result["status"] == "clarification_required"
        return [{
          "status" => "clarification_required",
          "route" => "clarification",
          "clarification" => {
            "question" => result.fetch("question"),
            "options" => result.fetch("options"),
            "requested_route" => "observe"
          },
          "result" => result
        }, "kg.observe"]
      end

      [{ "status" => "ok", "route" => decision.route, "result" => result }, "kg.observe"]
    end

    def search_response(text, decision)
      dataset_response = invoke("kg.datasets.query", "query" => text)
      return [{ "status" => "ok", "route" => decision.route, "result" => dataset_response.payload }, "kg.datasets.query"] if dataset_response.success?
      unless dataset_response.errors.first.to_h["code"] == "InvalidArguments"
        return [gateway_error(decision.route, dataset_response), "kg.datasets.query"]
      end

      response = invoke("kg.graph.query", "query" => text)
      if !response.success? && response.errors.first.to_h["code"] == "InvalidArguments"
        query = entity_query(text)
        response = invoke("kg.entities.search", "query" => query)
        capability = "kg.entities.search"
      else
        capability = "kg.graph.query"
      end
      return [gateway_error(decision.route, response), capability] unless response.success?

      matches = response.payload["matches"]
      if matches && matches.length > 1
        return [{
          "status" => "clarification_required",
          "route" => "clarification",
          "clarification" => {
            "question" => "Multiple identities match this query. Which one do you mean?",
            "options" => matches.map do |match|
              { "entity_id" => match["id"], "display_name" => match["name"], "entity_type" => match["type"] }
            end,
            "requested_route" => "search"
          }
        }, capability]
      end

      [{ "status" => "ok", "route" => decision.route, "result" => response.payload }, capability]
    end

    def proposal_response(text, decision)
      proposal_id = text[PROPOSAL_ID]
      unless proposal_id
        return [{
          "status" => "clarification_required",
          "route" => "proposal",
          "clarification" => {
            "question" => "Which proposal do you want to inspect? Provide its immutable proposal ID."
          }
        }, "kg.proposals.status"]
      end

      capability_response(decision, "kg.proposals.status", "proposal_id" => proposal_id)
    end

    def capability_response(decision, capability, arguments)
      response = invoke(capability, arguments)
      return [gateway_error(decision.route, response), capability] unless response.success?

      [{ "status" => "ok", "route" => decision.route, "result" => response.payload }, capability]
    end

    def invoke(capability_id, arguments)
      contract = @gateway.discover(agent: @agent).find do |item|
        item.fetch("capability_id") == capability_id
      end
      raise ChatError, "required capability is unavailable under policy: #{capability_id}" unless contract

      request = @gateway.issue_request(
        invocation_token: contract.fetch("invocation_token"), arguments: arguments
      )
      @gateway.execute(request: request, agent: @agent)
    end

    def gateway_error(route, response)
      error = response.errors.first || {
        "code" => "ExecutionFailed", "message" => "capability execution failed"
      }
      {
        "status" => "error",
        "route" => route,
        "error" => {
          "code" => error.fetch("code"),
          "message" => error.fetch("message")
        }
      }
    end

    def entity_query(text)
      ENTITY_QUERY_PATTERNS.each do |pattern|
        match = pattern.match(text.strip)
        return clean_query(match[1]) if match
      end
      clean_query(text)
    end

    def clean_query(value)
      value.to_s.sub(/[?!.]+\z/, "").strip
    end

    def intent_clarification
      {
        "status" => "clarification_required",
        "route" => "clarification",
        "clarification" => {
          "question" => "Do you want me to save this information or search for existing information?"
        }
      }
    end
  end
end
