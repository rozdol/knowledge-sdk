# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../lib/knowledge_graph"

module KnowledgeGraphTestSupport
  SDK_ROOT = File.expand_path("..", __dir__).freeze
  PERSONAL_CRM_PLUGIN = File.join(SDK_ROOT, "plugins/personal-crm").freeze

  def with_vault
    Dir.mktmpdir("knowledge-graph-engine-") { |root| yield root }
  end

  def with_schema_vault
    with_vault do |root|
      FileUtils.mkdir_p(File.join(root, "_System"))
      FileUtils.mkdir_p(File.join(root, "_System/Schema"))
      FileUtils.cp_r(
        File.join(PERSONAL_CRM_PLUGIN, "schemas"), File.join(root, "_System/Schema/Entity Types")
      )
      FileUtils.cp_r(
        File.join(PERSONAL_CRM_PLUGIN, "relationship_types"),
        File.join(root, "_System/Relationship Types")
      )
      yield root
    end
  end
end

class Minitest::Test
  include KnowledgeGraphTestSupport
end
