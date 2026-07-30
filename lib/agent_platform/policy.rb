# frozen_string_literal: true

module AgentPlatform
  class PolicyDecision
    attr_reader :allowed, :reason, :required_permissions, :approval

    def initialize(allowed:, reason:, required_permissions:, approval:)
      @allowed = !!allowed
      @reason = reason.to_s.freeze
      @required_permissions = Array(required_permissions).map(&:to_s).freeze
      @approval = approval.to_s.freeze
      freeze
    end

    def allowed?
      allowed
    end

    def to_h
      {
        allowed: allowed, reason: reason,
        required_permissions: required_permissions, approval: approval
      }
    end
  end

  class PolicyEngine
    def initialize(environment: "production", feature_flags: {}, approval_checker: nil,
                   time_policy: nil)
      @environment = environment.to_s
      @feature_flags = Value.immutable(feature_flags || {})
      @approval_checker = approval_checker || ->(_proposal_id) { false }
      @time_policy = time_policy
    end

    def discoverable?(manifest, agent:, session: nil)
      static_decision(manifest, agent: agent, session: session).allowed?
    end

    def evaluate(manifest, agent:, session:, arguments:)
      decision = static_decision(manifest, agent: agent, session: session)
      return decision unless decision.allowed?

      if manifest.approval == "existing_proposal_approval"
        argument = manifest.policy.fetch("proposal_id_argument")
        proposal_id = arguments[argument]
        unless proposal_id && @approval_checker.call(proposal_id)
          raise ApprovalRequired.new(
            "an immutable matching proposal approval is required",
            details: { proposal_id_argument: argument }
          )
        end
      end
      decision
    end

    private

    def static_decision(manifest, agent:, session:)
      return denied(manifest, "capability is disabled") if @feature_flags[manifest.capability_id] == false
      if @environment == "read_only" && manifest.effects != "read_only"
        return denied(manifest, "environment is read-only")
      end
      denied_capabilities = Array(agent.attributes["denied_capabilities"])
      return denied(manifest, "agent deny-list applies") if denied_capabilities.include?(manifest.capability_id)
      allowed_capabilities = Array(agent.attributes["allowed_capabilities"])
      if !allowed_capabilities.empty? && !allowed_capabilities.include?(manifest.capability_id)
        return denied(manifest, "capability is outside the agent allow-list")
      end
      missing = manifest.permissions.reject { |permission| agent.permits?(permission) }
      return denied(manifest, "required permissions are missing") unless missing.empty?
      if session && session.agent_id != agent.id
        return denied(manifest, "session belongs to another agent")
      end
      if @time_policy && !@time_policy.call(manifest, agent, session)
        return denied(manifest, "time policy denied the capability")
      end

      PolicyDecision.new(
        allowed: true, reason: "policy allowed", required_permissions: manifest.permissions,
        approval: manifest.approval
      )
    end

    def denied(manifest, reason)
      PolicyDecision.new(
        allowed: false, reason: reason, required_permissions: manifest.permissions,
        approval: manifest.approval
      )
    end
  end
end
