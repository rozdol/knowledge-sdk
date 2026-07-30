# frozen_string_literal: true

require_relative "agent_platform/value"
require_relative "agent_platform/errors"
require_relative "agent_platform/schema_validator"
require_relative "agent_platform/manifest"
require_relative "agent_platform/registry"
require_relative "agent_platform/models"
require_relative "agent_platform/session"
require_relative "agent_platform/policy"
require_relative "agent_platform/telemetry"
require_relative "agent_platform/jobs"
require_relative "agent_platform/security"
require_relative "agent_platform/services"
require_relative "agent_platform/handlers"
require_relative "agent_platform/gateway"
require_relative "agent_platform/plugins"
require_relative "agent_platform/generators"
require_relative "agent_platform/adapters/hermes"
require_relative "agent_platform/adapters/mcp"
require_relative "agent_platform/adapters/rest"
require_relative "agent_platform/adapters/cli"
require_relative "agent_platform/bootstrap"

module AgentPlatform
  VERSION = "7.0.0".freeze
end
