# frozen_string_literal: true

require "json"
require "stringio"
require_relative "test_support"

class KnowledgeActivityCLITest < Minitest::Test
  def test_every_command_emits_json_without_mixed_logs
    with_activity_vault do |root, engine, orchestrator, _timeline, set_time, clock|
      create_person(engine)
      set_time.call(10)
      engine.execute(KnowledgeGraph::UpdateEntity.new(
        entity_id: KnowledgeActivityTestSupport::PERSON_ID, changes: { pronouns: "she/her" }
      ))

      status, latest, error = run_activity(root, orchestrator, clock, "latest", "--json")
      assert_equal 0, status
      assert_empty error
      latest_payload = JSON.parse(latest)
      assert_equal "ok", latest_payload.fetch("status")
      latest_id = latest_payload.dig("activity", "id")

      commands = [
        ["recent", "--limit", "1", "--actor", "alex"],
        ["today", "--json"], ["yesterday", "--json"],
        ["since", "--time", "2026-08-01T09:30:00+03:00"],
        ["between", "--from", "2026-08-01T09:00:00+03:00", "--to", "2026-08-01T11:00:00+03:00"],
        ["search", "--query", "Ada", "--source", "knowledge-graph-engine"],
        ["explain", latest_id, "--limit", "1"],
        ["diff", "--from", JSON.parse(run_activity(root, orchestrator, clock, "recent")[1]).dig("activities", 1, "id"),
         "--to", latest_id]
      ]
      commands.each do |arguments|
        code, output, stderr = run_activity(root, orchestrator, clock, *arguments)
        assert_equal 0, code, arguments.join(" ")
        assert_empty stderr
        assert_equal "ok", JSON.parse(output).fetch("status")
      end
    end
  end

  def test_undo_latest_returns_a_review_only_proposal_json_contract
    with_activity_vault do |root, engine, orchestrator, _timeline, _set_time, clock|
      create_person(engine)
      status, output, error = run_activity(root, orchestrator, clock, "undo", "--latest", "--json")
      payload = JSON.parse(output)
      assert_equal 0, status
      assert_empty error
      assert_equal "ok", payload.fetch("status")
      assert_equal true, payload.fetch("approval_required")
      assert_match(/\Aproposal_[0-9A-HJKMNP-TV-Z]{26}\z/, payload.fetch("proposal"))
      assert_equal "active", repository_for(root).find(KnowledgeActivityTestSupport::PERSON_ID).data.fetch("record_status")
    end
  end

  private

  def run_activity(root, orchestrator, clock, *arguments)
    out = StringIO.new
    err = StringIO.new
    status = KnowledgeActivity::CLI.new(
      argv: arguments, out: out, err: err, vault_root: root,
      event_bus: orchestrator.event_bus, cache: orchestrator.cache, clock: clock
    ).run
    [status, out.string, err.string]
  end
end
