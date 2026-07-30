# frozen_string_literal: true

require_relative "test_support"

class OrchestrationWorkflowCacheTest < Minitest::Test
  Snapshot = Struct.new(:digest)

  def test_cache_reuses_only_derived_output_and_invalidates_by_dependency
    with_vault do |root|
      invoker = FakeInvoker.new
      cache = KnowledgeOrchestration::KnowledgeCache.new(vault_root: root, clock: -> { ORCHESTRATION_FIXED_TIME })
      history = KnowledgeOrchestration::WorkflowHistoryStore.new(vault_root: root)
      engine = KnowledgeOrchestration::WorkflowEngine.new(
        invoker: invoker, cache: cache, history: history,
        snapshot_provider: -> { Snapshot.new("snapshot_A") }, clock: -> { ORCHESTRATION_FIXED_TIME }
      )
      workflow = cached_workflow
      first = engine.execute(
        workflow: workflow,
        event: orchestration_event(type: "ReminderDue", id_suffix: "1", payload: { "value" => "same" })
      )
      second = engine.execute(
        workflow: workflow,
        event: orchestration_event(type: "ReminderDue", id_suffix: "2", payload: { "value" => "same" })
      )

      assert_equal 1, invoker.calls.length
      refute first.steps.first.fetch("cache_hit")
      assert second.steps.first.fetch("cache_hit")
      artifact = cache.list.first
      assert_equal "analysis", artifact.artifact_type
      assert_equal "snapshot_A", artifact.dependencies.snapshot_digest
      dependency_types = artifact.dependencies.event_ids.map do |id|
        history.list.find { |execution| execution.event.id == id }&.event&.type
      end.compact
      assert_equal ["ReminderDue", "ReminderDue"], dependency_types
      assert_equal 2, artifact.dependencies.event_ids.length
      refute artifact.value.key?("facts")
      refute artifact.value.key?("graph")

      invalidating = orchestration_event(type: "RelationshipUpdated", id_suffix: "3")
      assert_equal [artifact.id], cache.invalidate(invalidating, new_snapshot_digest: "snapshot_A")
      assert_equal "stale", cache.fetch_artifact(artifact.id).status

      engine.execute(
        workflow: workflow,
        event: orchestration_event(type: "ReminderDue", id_suffix: "4", payload: { "value" => "same" })
      )
      assert_equal 2, invoker.calls.length
    end
  end

  def test_retry_and_replay_are_deterministic
    with_vault do |root|
      snapshot_digest = "snapshot_A"
      invoker = FakeInvoker.new(failures: 1)
      cache = KnowledgeOrchestration::KnowledgeCache.new(vault_root: root, clock: -> { ORCHESTRATION_FIXED_TIME })
      history = KnowledgeOrchestration::WorkflowHistoryStore.new(vault_root: root)
      engine = KnowledgeOrchestration::WorkflowEngine.new(
        invoker: invoker, cache: cache, history: history,
        snapshot_provider: -> { Snapshot.new(snapshot_digest) }, clock: -> { ORCHESTRATION_FIXED_TIME }
      )
      workflow = cached_workflow(retries: 1)
      event = orchestration_event(type: "ReminderDue", payload: { "value" => "stable" })
      original = engine.execute(workflow: workflow, event: event)
      replayed = engine.execute(workflow: workflow, event: event, replay: true)

      assert_equal 2, original.steps.first.fetch("attempts")
      assert_equal original.output_digest, replayed.output_digest
      assert_equal original.id, replayed.id

      snapshot_digest = "snapshot_B"
      assert_raises(KnowledgeOrchestration::WorkflowExecutionFailed) do
        engine.execute(workflow: workflow, event: event, replay: true)
      end
    end
  end

  def test_failed_durable_job_can_be_resumed_explicitly
    with_vault do |root|
      manager = KnowledgeOrchestration::DurableJobManager.new(
        vault_root: root, clock: -> { ORCHESTRATION_FIXED_TIME }
      )
      event = orchestration_event(type: "ReminderDue")
      workflow = cached_workflow
      failed = manager.submit(event: event, workflow: workflow) { |_progress| raise "synthetic" }
      assert_equal "failed", failed.status
      assert_equal [failed.id], manager.resumable.map(&:id)

      result = Struct.new(:id, :output_digest).new("workflow-run_synthetic", "digest")
      resumed = manager.submit(event: event, workflow: workflow, force: true) { |_progress| result }
      assert_equal "succeeded", resumed.status
      assert_empty manager.resumable
    end
  end

  def test_durable_job_supports_background_execution
    with_vault do |root|
      manager = KnowledgeOrchestration::DurableJobManager.new(
        vault_root: root, clock: -> { ORCHESTRATION_FIXED_TIME }, threaded: true
      )
      result = Struct.new(:id, :output_digest).new("workflow-run_background", "digest")
      job = manager.submit(
        event: orchestration_event(type: "ReminderDue"), workflow: cached_workflow
      ) do |_progress|
        sleep 0.01
        result
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.0
      until job.terminal? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.005
        job = manager.fetch(job.id)
      end
      assert_equal "succeeded", job.status
      assert_equal 100, job.to_h.fetch("progress")
    end
  end

  def test_workflow_rejects_automatic_engine_submission_and_cycles
    assert_raises(KnowledgeOrchestration::InvalidWorkflow) do
      KnowledgeOrchestration::WorkflowDefinition.new(
        id: "unsafe", version: "1.0.0", on: ["ReminderDue"],
        steps: [{ id: "submit", capability: "kg.proposals.submit" }]
      )
    end
    assert_raises(KnowledgeOrchestration::InvalidWorkflow) do
      KnowledgeOrchestration::WorkflowDefinition.new(
        id: "cycle", version: "1.0.0", on: ["ReminderDue"],
        steps: [
          { id: "a", capability: "plugin.a", depends_on: ["b"] },
          { id: "b", capability: "plugin.b", depends_on: ["a"] }
        ]
      )
    end
  end
end
