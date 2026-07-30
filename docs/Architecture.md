# Architecture Guide

## Boundary

Canonical facts remain in schema-v1.0 Markdown frontmatter. The Engine is a storage boundary, not a new database: runtime receipts and the audit log contain execution metadata and can be rebuilt or removed without changing graph facts. Disposable SQLite or Neo4j indexes may be added later behind the same Intent API.

## One execution pipeline

Every public write reaches `Engine#execute` and follows one path:

```text
immutable Intent
  -> before_execute hook
  -> durable receipt lookup
  -> dispatcher / capability handler
  -> staged filesystem transaction
  -> candidate-vault validate_vault.rb
  -> before_commit hook
  -> optimistic concurrency check
  -> atomic file replacement + receipt commit
  -> after_commit hook
  -> replayable JSONL audit event
```

The Agent Platform is the public authorization and capability-dispatch boundary for Hermes, MCP, REST-style clients, and new agent integrations. Existing direct Engine calls remain an internal/local SDK compatibility surface. Proposal submission still reaches `Engine#execute`, so Agent Platform policy augments rather than replaces Engine approval gates.

## Planning and decision pipeline

Phase 8 is a read-only decision layer above the graph snapshot and Intelligence features. Planning and decision are deliberately separate:

```text
immutable Goal + composable Constraints
  -> Candidate Plan Generator (one or more deterministic planners)
  -> Scenario Evaluator (simulation, features, hard-constraint checks)
  -> Decision Engine (shared policy, Pareto frontier, stable ranking)
  -> decision-approved Plan + alternatives + machine-readable trace
  -> optional review-only Intent Proposal
  -> existing explicit human approval
  -> existing Engine
```

“Decision-approved” means only that a plan ranked first after hard constraints. It is not human approval and gives no execution authority. The planning module has no Engine, dispatcher, repository writer, or autonomous-agent dependency. Given the same graph snapshot, goal, constraints, policy, and `as_of` date, its canonical result is identical.

## Agent execution pipeline

```text
policy-filtered manifest discovery
  -> opaque invocation token
  -> immutable AgentRequest
  -> manifest input validation
  -> centralized policy and exact approval check
  -> private handler binding
  -> existing Graph / Extraction / Intelligence API
  -> manifest output validation and leak guard
  -> structured AgentResponse + sanitized telemetry
```

Agents cannot dispatch arbitrary capability names. Transport strings are selectors only: an adapter resolves them against current policy-filtered discovery and invokes the Gateway with the manifest-issued opaque token.

## Modules

- `intents.rb` defines immutable commands and their serialization contract.
- `executor/` owns dispatch, hooks, locks, optimistic concurrency, commit, and rollback.
- `storage/` parses canonical notes, loads schema v1.0, generates deterministic flat YAML, resolves paths, and preserves bodies.
- `validation/` builds an isolated candidate vault and invokes the existing validator before live changes.
- `graph/` validates predicates, endpoint types, symmetric ordering, retractions, replacements, and duplicate signatures.
- `identity/` indexes exact identity signals, follows merge redirects, and performs atomic merge/split operations.
- `audit/` stores local JSONL events and transactionally committed idempotency receipts.
- `cli/` exposes the same SDK capabilities without a second execution path.
- `knowledge_planning/` owns immutable goals and plans, constraint evaluation, graph search, candidate planners, scenario simulation, shared decision policy, explanations, traces, and review-proposal adaptation. It never mutates the graph.
- `agent_platform/` owns manifests, Registry, Gateway, policy, sessions, adapters, jobs, telemetry, plugins, and generated contract artifacts. It does not parse Markdown or YAML.

## Transaction guarantees

Files are staged in memory. Before commit, the Engine re-reads every affected live file and compares its SHA-256 fingerprint with the inspected snapshot. A mismatch aborts without restoring stale content. Commit uses same-directory temporary files and rename; any mid-commit exception restores all pre-write snapshots. A vault-specific process lock serializes Engine writers.

The candidate validator receives copies of all validation-relevant Markdown and the staged overlay. Invalid changes never touch the live vault. The validator is mandatory; a missing validator blocks execution.

## YAML and bodies

The writer accepts only scalars and flat scalar lists, emits canonical property order, quotes strings (therefore every wiki link), and rejects nested YAML. Update operations preserve unknown keys and all body bytes. Body-writing capabilities operate only in named `AGENT-MANAGED` sections; merge and rename may perform verified wiki-link target rewrites required for graph consistency.

## Relationships

One Relationship note is one canonical edge. Symmetric predicates sort endpoints by immutable ID. Inverses are registry/query semantics, so the Engine does not create a mirrored second edge. `RemoveRelationship` retracts rather than deletes. `ReplaceRelationship` retracts the original and asserts its replacement in one transaction.

## Identity and merge

Exact IDs and merged redirects resolve first, followed by strong normalized identifiers. Names and aliases generate candidates but never authorize a merge. Person merge/split requires `human_approved: true`. Merge preserves the losing body in its redirect stub, rewrites verified links and sibling IDs, reorders symmetric roles, and retracts duplicate edge signatures. Conflicting non-policy scalar facts abort the merge.

## Idempotency and audit

An Intent fingerprint is SHA-256 over canonical JSON serialization. A successful command stages `_System/KnowledgeGraph/Runtime/receipts/<fingerprint>.json` in the same transaction as graph changes. Re-execution validates the vault and returns the stored result with `replayed: true`.

Each attempt appends a local JSONL audit event containing timestamp, Intent payload, affected IDs, result, duration, rollback flag, replay flag, run ID, and future actor ID. Runtime data is local and Git-ignored; it is operational history, never a source of canonical facts.
