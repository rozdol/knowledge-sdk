# frozen_string_literal: true

require_relative "knowledge_planning/errors"
require_relative "knowledge_planning/model"
require_relative "knowledge_planning/constraints"
require_relative "knowledge_planning/goals"
require_relative "knowledge_planning/graph_search"
require_relative "knowledge_planning/planners"
require_relative "knowledge_planning/simulation"
require_relative "knowledge_planning/scenarios"
require_relative "knowledge_planning/decision"
require_relative "knowledge_planning/proposals"
require_relative "knowledge_planning/engine"
require_relative "knowledge_planning/cli"

module KnowledgePlanning
  VERSION = "8.0.0".freeze
end
