# frozen_string_literal: true

require "json"
require "stringio"
require_relative "../test_helper"

module StructuredDatasetTestSupport
  RUN_ID = "run_01KYYD4HNT4HEWNH1P3DQKTPPE"
  SELF_ID = "person_01KYYD4HNT4HEWNH1P3DQKTPPF"
  FIXED_TIME = Time.utc(2026, 8, 1, 10, 0, 0)

  def dataset_engine(root, event_bus: nil)
    StructuredDataset::Engine.new(
      vault_root: root, run_id: RUN_ID, actor_id: "dataset-test", event_bus: event_bus,
      clock: -> { FIXED_TIME }
    )
  end

  def create_self(root)
    KnowledgeGraph::Engine.new(
      vault_root: root, run_id: RUN_ID, clock: -> { FIXED_TIME }
    ).execute(
      KnowledgeGraph::CreateEntity.new(
        entity_type: "person",
        attributes: {
          id: SELF_ID, name: "Dataset Test Self", tier: "active", sensitivity: "private",
          data_origin: "given_by_subject", is_self: true, emails: [], phones: [], external_ids: []
        }
      )
    )
  end

  def run_cli(root, *arguments, stdin: StringIO.new)
    out = StringIO.new
    err = StringIO.new
    status = KnowledgeGraph::CLI.run(
      ["--vault", root, "--run-id", RUN_ID, "--actor-id", "dataset-test", *arguments],
      out: out, err: err, stdin: stdin
    )
    [status, out.string, err.string]
  end
end

class Minitest::Test
  include StructuredDatasetTestSupport
end
