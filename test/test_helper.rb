# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/knowledge_graph"

module KnowledgeGraphTestSupport
  def with_vault
    Dir.mktmpdir("knowledge-graph-engine-") { |root| yield root }
  end
end

class Minitest::Test
  include KnowledgeGraphTestSupport
end
