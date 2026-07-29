# frozen_string_literal: true

require "digest"
require "stringio"
require_relative "test_support"

class IntelligenceCLIIntegrationTest < Minitest::Test
  RUN_ID = "run_01KYQJDK7ME8S8GDAX9HHE08VR"

  class SyntheticIdGenerator
    def initialize
      @counter = 0
    end

    def generate(prefix)
      @counter += 1
      KnowledgeExtraction::Support.stable_id(prefix, "intelligence-cli-test", @counter)
    end
  end

  def test_cli_reads_engine_created_graph_without_mutating_markdown
    with_schema_vault do |root|
      engine = KnowledgeGraph::Engine.new(
        vault_root: root, run_id: RUN_ID, id_generator: SyntheticIdGenerator.new,
        clock: -> { Time.utc(2026, 7, 29, 9, 0, 0) }
      )
      self_result = engine.execute(KnowledgeGraph::CreateEntity.new(
        entity_type: "person",
        attributes: {
          name: "Synthetic Owner", tier: "inner", sensitivity: "private",
          data_origin: "public", is_self: true
        }
      ))
      contact_result = engine.execute(KnowledgeGraph::CreateEntity.new(
        entity_type: "person",
        attributes: {
          name: "Synthetic Contact", tier: "active", sensitivity: "private",
          data_origin: "given_by_subject"
        }
      ))
      reader = KnowledgeGraph::GraphReader.new(vault_root: root)
      engine.execute(KnowledgeGraph::RecordInteraction.new(attributes: {
        name: "Synthetic contact call", starts_at: "2026-07-20T09:00:00Z",
        participants: [reader.find(self_result.entity_ids.first).link, reader.find(contact_result.entity_ids.first).link],
        interaction_kind: "call", contact_weight: "substantive",
        sensitivity: "private", data_origin: "given_by_subject"
      }))
      before = markdown_hashes(root)
      out = StringIO.new
      err = StringIO.new

      status = KnowledgeGraph::CLI.run(
        ["--vault", root, "intelligence", "features", "--person", "Synthetic Contact", "--as-of", "2026-07-29"],
        out: out, err: err, stdin: StringIO.new
      )

      assert_equal 0, status, err.string
      payload = JSON.parse(out.string)
      assert_equal contact_result.entity_ids.first, payload.fetch("entity_id")
      assert_includes payload.fetch("features").map { |item| item.fetch("name") }, "relationship_strength"
      assert_equal before, markdown_hashes(root)
    end
  end

  private

  def markdown_hashes(root)
    Dir.glob(File.join(root, "**/*.md")).sort.each_with_object({}) do |path, result|
      result[path.sub("#{root}/", "")] = Digest::SHA256.file(path).hexdigest
    end
  end
end
