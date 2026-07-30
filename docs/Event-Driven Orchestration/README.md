# Event-Driven Orchestration

Phase 9 adds deterministic coordination above the stable Engine, Extraction, Intelligence, Planning, Decision, and Agent Platform layers. It does not move business decisions into the Orchestrator and does not create a second write path.

## Invariants

- Events are immutable, versioned, append-only, and deterministically ordered by their persisted sequence.
- Workflow definitions are declarative YAML. Steps form a validated acyclic dependency graph.
- Every workflow capability is discovered and invoked through the Agent Gateway.
- Workflow validation rejects `kg.proposals.submit`; runtime invocation also rejects graph-write and existing-approval capabilities.
- Extraction and planning workflows may create review-only proposals. Approval and submission remain separate human operations.
- Notifications are informational runtime artifacts with `executable: false`.
- Event, workflow, job, notification, and cache state lives under Git-ignored `_System/KnowledgeGraph/Runtime/orchestration/`; it is not canonical graph truth.

## Event bus

Each event contains `event_id`, microsecond timestamp, source, type, immutable payload, correlation ID, optional causation ID, trace ID, schema version, and persisted sequence. The internal bus supports filtered subscriptions, replay, a dead-letter queue, event-type/version registration, and stable subscriber order. `EventRegistry` and `PluginRegistrar` allow adapters or plugins to add event versions and workflows without editing the Orchestrator.

The file-backed adapter is intentionally internal. `EventStore` and `EventBus` are separate, so a future Kafka, NATS, or RabbitMQ adapter can implement the same publish/replay boundary.

## Workflows and policy

`config/workflows.yml` defines triggers, optional conditions, steps, arguments, dependencies, timeouts, retries, cache policy, and outputs. Templates use `$event.payload.field`, `$steps.step_id.payload.field`, `$snapshot.digest`, or `{{path}}` interpolation. Topological ordering uses step IDs as the deterministic tie-breaker.

The shipped workflows cover meeting and transcript extraction, goal planning, deadline review, overdue follow-ups, planner completion, approved and rejected proposals, relationship changes, requested digests, and scheduled health reviews. Proposal approval never causes automatic submission; it produces a notification saying manual submission is still required.

Plugins register a versioned Agent Platform manifest plus a trusted handler, then reference that capability from a workflow step. This keeps plugin execution behind the same schema, policy, timeout, and output-security checks as core capabilities.

## Knowledge Cache

The Knowledge Cache does not cache facts, canonical Markdown, graph records, graph queries as an alternate truth, or mutable graph state. It caches only expensive derived computation artifacts:

- analyzer results;
- deterministic plans and recommendations;
- reports and briefing packages;
- daily, weekly, and monthly digests;
- other bounded workflow outputs.

Every cached artifact has explicit dependencies:

- originating event IDs;
- event types that invalidate it;
- immutable graph snapshot digest;
- producing capability ID and version;
- optional entity IDs that narrow invalidation scope.

The cache key includes capability, arguments, and snapshot digest. Reuse therefore requires an exact snapshot match. On a new event, `DependencyGraph` marks only matching artifacts stale; entity-scoped dependencies avoid unrelated recomputation. Cache status is operational metadata and never feeds facts back into the graph.

## Scheduler and jobs

`config/schedules.yml` supports five-field cron expressions with wildcards, lists, ranges, and steps. A schedule emits an ordinary event with a stable correlation/trace identity for the minute slot. `SchedulerState` makes each schedule slot idempotent.

Each triggered workflow receives a durable job record with ID, status, progress, result reference, trace ID, retry state, timestamps, and resumability. Queued or interrupted jobs can be resumed; cancellation changes only operational state.

## Replay and observability

Workflow identity is a stable digest of workflow definition, input event, and snapshot. Replay invokes the same Gateway capabilities and compares the logical output digest; request IDs, latency, attempts, and cache-hit flags are excluded from the deterministic digest. Divergence raises an error.

Workflow and event timelines expose identifiers, status, dependency edges, capability versions, latency, retry counts, cache usage, and output digests. They omit capability arguments and raw output payloads so observability does not become a sensitive graph-data channel.

## CLI

```sh
ruby "_System/KnowledgeGraph/bin/kg" workflow list
ruby "_System/KnowledgeGraph/bin/kg" workflow run digest_requested \
  '{"period":"daily","as_of":"2026-07-30"}'
ruby "_System/KnowledgeGraph/bin/kg" workflow trace workflow-run_<ULID>
ruby "_System/KnowledgeGraph/bin/kg" workflow jobs
ruby "_System/KnowledgeGraph/bin/kg" events list --type GraphChanged
ruby "_System/KnowledgeGraph/bin/kg" events replay event_<ULID>
ruby "_System/KnowledgeGraph/bin/kg" scheduler run --at 2026-07-30T07:00:00+03:00
ruby "_System/KnowledgeGraph/bin/kg" notifications list
ruby "_System/KnowledgeGraph/bin/kg" cache graph
```

Use `kg replay AUDIT_ID` only for Engine audit replay. `kg events replay EVENT_ID` and `kg workflow replay EXECUTION_ID` are orchestration replay commands.

## Verification

```sh
ruby -I"_System/KnowledgeGraph/lib" -I"_System/KnowledgeGraph/test" \
  -e 'Dir["_System/KnowledgeGraph/test/orchestration/**/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
ruby -I"_System/KnowledgeGraph/lib" -I"_System/KnowledgeGraph/test" \
  -e 'Dir["_System/KnowledgeGraph/test/**/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
ruby "_System/KnowledgeGraph/bin/kg" doctor
ruby "_System/Tools/validate_vault.rb"
```
