# Knowledge Activity

Knowledge Activity is the human-oriented temporal API for the Knowledge Graph platform. It is a projection, not a canonical record and not a new storage system.

## Architecture

The timeline begins with successful, non-replayed audit receipts that changed canonical paths. It enriches each receipt from infrastructure that already exists:

```text
Activity view
  -> Engine audit receipt (execution and affected IDs)
  -> Event Bus (source, trace, and domain events)
  -> Proposal Store (origin, evidence, approval, and submission)
  -> current Graph Snapshot (display labels and sensitivity)
  -> Replay-compatible stable state digest
```

`activity_<ULID>` is a stable projection of `audit_<ULID>`. No Activity file, table, event stream, or Markdown note is created. Current display labels are read from the graph; restricted changes are redacted from summaries, affected-object lists, search, and explanations.

The existing Knowledge Cache may retain this fully regenerable projection using audit, proposal, event-history, and graph-snapshot digests. `GraphChanged` invalidation and snapshot matching prevent stale reuse. The cache remains derived operational data and never writes facts back to the graph.

Undo and restore use the existing review path:

```text
Activity -> lossless reverse/forward Intent plan -> immutable Proposal
  -> exact proposal fingerprint -> explicit human approval
  -> Proposal Submitter -> Engine -> validator -> audit/event history
```

The command never calls the Engine. It stores only a new review-only proposal and emits the existing `ProposalCreated` event. Unsupported or lossy reversals are reported as unavailable. Graph objects are archived, restored, or retracted through existing Intents; they are never deleted.

## Commands

```sh
kg activity latest [--json]
kg activity recent [--limit N]
kg activity today
kg activity yesterday
kg activity since --time TIME
kg activity between --from TIME --to TIME
kg activity search --query TEXT
kg activity explain ACTIVITY_ID
kg activity undo ACTIVITY_ID
kg activity undo --latest
kg activity restore ACTIVITY_ID
kg activity diff FROM_ACTIVITY TO_ACTIVITY
```

Every command accepts `--json`, `--limit`, `--actor`, and `--source`. JSON is always emitted, including when `--json` is omitted. `--json` is retained as an explicit client contract. Diagnostics and errors go only to stderr, with no ANSI formatting.

## Response contracts

- `latest` returns `{status, activity}`.
- Timeline and search commands return `{status, activities, count}` ordered newest first.
- `explain` returns origin, exact policy-visible evidence, proposal, approval, execution, and resulting changes.
- `undo` and `restore` return `{status, proposal, summary, approval_required, activity, operation}`. They never return an executed graph change.
- `diff` returns stable from/to state digests and categorized affected object IDs between the two states.

Schemas are defined in [activity.schema.json](activity.schema.json) and [response.schema.json](response.schema.json).

## Examples

```sh
ruby "_System/KnowledgeGraph/bin/kg" activity latest --json
```

```json
{
  "status": "ok",
  "activity": {
    "id": "activity_01KYYA00000000000000000000",
    "type": "knowledge_added",
    "summary": "Ivan Petrov was added.",
    "created_at": "2026-08-01T11:23:00+03:00",
    "source": "telegram",
    "actor": "alex",
    "proposal": "proposal_01KYYA00000000000000000001",
    "events": ["event_01KYYA00000000000000000002"],
    "affected_objects": [{"id":"person_01KYYA00000000000000000003","kind":"person","name":"Ivan Petrov","state":"active"}],
    "undo_available": true,
    "restore_available": true,
    "privacy": "visible"
  }
}
```

```sh
ruby "_System/KnowledgeGraph/bin/kg" activity undo --latest --json
```

```json
{
  "status": "ok",
  "proposal": "proposal_01KYYA00000000000000000004",
  "summary": "Undo activity activity_01KYYA00000000000000000000: Ivan Petrov was added.",
  "approval_required": true,
  "activity": "activity_01KYYA00000000000000000000",
  "operation": "undo"
}
```

```sh
ruby "_System/KnowledgeGraph/bin/kg" activity today --json
```

```json
{"status":"ok","activities":[],"count":0}
```

```sh
ruby "_System/KnowledgeGraph/bin/kg" activity explain activity_01KYYA00000000000000000000 --json
```

The explanation response preserves the same Activity object and adds `origin`, `evidence`, `proposal`, `approval`, `execution`, and `resulting_changes`. Restricted evidence is represented as `{"redacted":true}`.
