# frozen_string_literal: true

require "json"
require "stringio"
require_relative "test_helper"

class CLITest < Minitest::Test
  PERSON_ID = "person_01K1D9VB96W7CS7F4M7K8Q2Z0A"
  RUN_ID = "run_01KYQADDKGCXF0H38JFT5EN0CV"

  def test_stats_search_execute_validate_and_replay
    with_schema_vault do |root|
      create_person(root)

      status, stats = run_cli(root, "stats")
      assert_equal 0, status
      assert_equal 1, JSON.parse(stats).fetch("total")

      status, search = run_cli(root, "search", "Ada")
      assert_equal 0, status
      assert_equal PERSON_ID, JSON.parse(search).fetch("matches").first.fetch("id")

      payload = JSON.generate(intent: "ArchiveEntity", params: { entity_id: PERSON_ID })
      status, archived = run_cli(root, "execute", payload)
      archived_result = JSON.parse(archived)
      assert_equal 0, status
      refute archived_result.fetch("replayed")
      assert_equal "archived", repository_for(root).find(PERSON_ID).data["record_status"]

      status, replayed = run_cli(root, "replay", archived_result.fetch("audit_id"))
      assert_equal 0, status
      assert JSON.parse(replayed).fetch("replayed")

      status, validator_output = run_cli(root, "validate")
      assert_equal 0, status
      assert_includes validator_output, "OK:"

      status, doctor = run_cli(root, "doctor")
      assert_equal 0, status
      assert_equal 18, JSON.parse(doctor).fetch("schemas")
    end
  end

  private

  def create_person(root)
    fixed_time = Time.new(2026, 7, 29, 10, 0, 0, "+03:00")
    engine = KnowledgeGraph::Engine.new(vault_root: root, run_id: RUN_ID, clock: -> { fixed_time })
    engine.execute(
      KnowledgeGraph::CreateEntity.new(
        entity_type: "person",
        attributes: {
          id: PERSON_ID, name: "Ada", tier: "active", sensitivity: "private",
          data_origin: "public", is_self: true
        }
      )
    )
  end

  def run_cli(root, *arguments)
    out = StringIO.new
    err = StringIO.new
    status = KnowledgeGraph::CLI.run(["--vault", root, "--run-id", RUN_ID, *arguments], out: out, err: err)
    unexpected = err.string.lines.reject { |line| line.start_with?("WARN:") }.join
    assert_empty unexpected if status.zero?
    [status, out.string]
  end

  def repository_for(root)
    registry = KnowledgeGraph::SchemaRegistry.new(vault_root: root)
    KnowledgeGraph::Repository.new(vault_root: root, registry: registry)
  end
end
