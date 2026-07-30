# frozen_string_literal: true

require_relative "knowledge_extraction/errors"
require_relative "knowledge_extraction/support"
require_relative "knowledge_extraction/configuration"
require_relative "knowledge_extraction/sources"
require_relative "knowledge_extraction/evidence"
require_relative "knowledge_extraction/facts"
require_relative "knowledge_extraction/dates"
require_relative "knowledge_extraction/providers"
require_relative "knowledge_extraction/structured_output"
require_relative "knowledge_extraction/resolution"
require_relative "knowledge_extraction/planning"
require_relative "knowledge_extraction/proposal"
require_relative "knowledge_extraction/observability"
require_relative "knowledge_extraction/store"
require_relative "knowledge_extraction/renderers"
require_relative "knowledge_extraction/submission"
require_relative "knowledge_extraction/pipeline"
require_relative "knowledge_extraction/observation"
require_relative "knowledge_extraction/observation_cli"
require_relative "knowledge_extraction/evaluation"
require_relative "knowledge_extraction/cli"

module KnowledgeExtraction
  VERSION = "5.0.0".freeze
end
