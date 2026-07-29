# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../lib/knowledge_graph"

module KnowledgeGraphTestSupport
  def with_vault
    Dir.mktmpdir("knowledge-graph-engine-") { |root| yield root }
  end

  def with_schema_vault
    with_vault do |root|
      source_root = File.expand_path("../../..", __dir__)
      FileUtils.mkdir_p(File.join(root, "_System"))
      FileUtils.cp_r(File.join(source_root, "_System/Schema"), File.join(root, "_System/Schema"))
      FileUtils.cp_r(
        File.join(source_root, "_System/Relationship Types"),
        File.join(root, "_System/Relationship Types")
      )
      FileUtils.mkdir_p(File.join(root, "_System/Tools"))
      FileUtils.cp(
        File.join(source_root, "_System/Tools/validate_vault.rb"),
        File.join(root, "_System/Tools/validate_vault.rb")
      )
      yield root
    end
  end
end

class Minitest::Test
  include KnowledgeGraphTestSupport
end
