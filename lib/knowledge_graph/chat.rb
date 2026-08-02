# frozen_string_literal: true

module KnowledgeGraph
  class ChatError < Error; end

  class ChatIntentResolver
    Decision = Struct.new(
      :route, :reason, :capability, :intent, :confidence, :slots,
      keyword_init: true
    )

    PLAN_REQUEST = /\A(?:(?:please\s+)?(?:(?:make|create|build|draft|develop|prepare)\b.*\bplan\b|plan\b)|(?:пожалуйста\s+)?(?:создай|составь|подготовь)\b.*\bплан\b|(?:παρακαλώ\s+)?(?:δημιούργησε|ετοίμασε|σύνταξε)\b.*\bσχέδιο\b)/i.freeze
    SEARCH_REQUEST = /\A(?:who|what|where|when|which|why|how|does|do|did|is|are|was|were|can|could|would|tell\s+me|show\s+me|find|кто|что|где|когда|какой|почему|как|найди|покажи|расскажи|ποιος|ποια|ποιο|τι|πού|πότε|γιατί|πώς|βρες|δείξε)\b/i.freeze
    UNSUPPORTED_ACTION = /\A(?:please\s+)?(?:add|archive|approve|call|change|delete|edit|email|execute|merge|remove|rename|schedule|send|submit|update)\b/i.freeze

    CAPABILITIES = {
      "dataset" => "kg.datasets.propose", "observe" => "kg.observe",
      "analyze" => "kg.analysis.run",
      "search" => "kg.graph.query", "plan" => "kg.planning.plan",
      "proposal" => "kg.proposals.status"
    }.freeze

    class << self
      def classifier
        classifier = KnowledgeSDK.intent_classifier
        install_defaults(classifier)
        classifier
      end

      def install_defaults(classifier)
        StructuredDataset::IntentClassifierPlugin.register(classifier)
        KnowledgeAnalysis::IntentClassifierPlugin.register(classifier)
        classifier.register(name: "core-search", domain: "generic", route: "search") do |source, _context|
          next nil if proposal_request?(source)
          next nil unless SEARCH_REQUEST.match?(source) || source.end_with?("?")

          {
            "intent" => "graph.search", "confidence" => 0.90,
            "explanation" => "informational question about existing knowledge"
          }
        end
        classifier.register(name: "core-plan", domain: "generic", route: "plan") do |source, _context|
          next nil unless PLAN_REQUEST.match?(source)

          {
            "intent" => "planner.goal", "confidence" => 0.95,
            "explanation" => "explicit request to create a plan"
          }
        end
        classifier.register(name: "core-proposal", domain: "generic", route: "proposal") do |source, _context|
          next nil unless proposal_request?(source)

          {
            "intent" => "proposal.status", "confidence" => 0.98,
            "explanation" => "request concerns an existing proposal"
          }
        end
        classifier.register(
          name: "core-graph-observe", domain: "generic", route: "observe", fallback: true
        ) do |source, _context|
          next nil if UNSUPPORTED_ACTION.match?(source) || source.split(/\s+/).length < 3

          {
            "intent" => "graph.observe", "confidence" => 0.20,
            "explanation" => "no specialized, planning, or search classifier matched; using graph observation as a last resort"
          }
        end
      end

      def proposal_request?(source)
        return true if source.match?(/\bproposal_[0-9A-HJKMNP-TV-Z]{26}\b/)
        return false unless source.match?(/\bproposals?\b/i)

        source.end_with?("?") || source.match?(
          /\A(?:please\s+)?(?:show|list|inspect|check|review|open|find|create|make)\b|\bpending\b|\bstatus\b/i
        )
      end
    end

    def initialize(classifier: self.class.classifier)
      @classifier = classifier
    end

    def resolve(text, context = {})
      source = text.to_s.strip
      raise ChatError, "chat text is empty" if source.empty?

      classification = @classifier.classify(source, context)
      unless classification
        reason = if UNSUPPORTED_ACTION.match?(source)
                   "requested action is not safely covered by a chat route"
                 elsif source.split(/\s+/).length < 3
                   "message is too short to distinguish an observation from a query"
                 else
                   "message intent is ambiguous"
                 end
        return decision("clarification", reason, nil, "chat.clarification", 0.0, {})
      end

      decision(
        classification.route, classification.reason, CAPABILITIES[classification.route],
        classification.intent, classification.confidence, classification.slots
      )
    end

    private

    def decision(route, reason, capability, intent, confidence, slots)
      Decision.new(
        route: route, reason: reason, capability: capability,
        intent: intent, confidence: confidence, slots: slots
      ).freeze
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
        permissions: %w[
          graph:read dataset:read intelligence:read analysis:read planning:read proposal:read proposal:create
        ],
        roles: ["chat_client"],
        attributes: {
          "autonomous_execution" => false,
          "allowed_capabilities" => %w[
            kg.entities.search kg.graph.query kg.datasets.query kg.datasets.propose
            kg.analysis.run kg.planning.plan kg.proposals.status
          ],
          "denied_capabilities" => ["kg.proposals.submit"]
        }
      )
    end

    def route(text, explain: false, context: {})
      decision = @resolver.resolve(text, context)
      response, capability = case decision.route
                             when "dataset" then dataset_response(decision, context)
                             when "analyze" then capability_response(
                               decision, "kg.analysis.run", "question" => text
                             )
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
          "capability" => capability,
          "intent" => decision.intent,
          "confidence" => decision.confidence
        }
      end
      response
    end

    private

    def dataset_response(decision, arguments)
      response = invoke("kg.datasets.propose", arguments)
      return [gateway_error(decision.route, response), "kg.datasets.propose"] unless response.success?

      if response.payload["status"] == "clarification_required"
        return [{
          "status" => "clarification_required", "route" => "dataset",
          "clarification" => {
            "question" => response.payload.fetch("question"), "requested_route" => "dataset"
          },
          "result" => response.payload
        }, "kg.datasets.propose"]
      end

      [{ "status" => "ok", "route" => "dataset", "result" => response.payload }, "kg.datasets.propose"]
    end

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
