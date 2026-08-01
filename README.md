# Knowledge Graph Engine SDK

The Knowledge Graph Engine is the only automated write interface for canonical vault notes. Callers submit immutable Intents; the Engine resolves identities, stages Markdown changes, validates a candidate vault, commits atomically, and records replay metadata. Markdown remains the only canonical source of facts.

The package runs on Ruby 2.6 or newer. The Structured Dataset Engine additionally requires the local `sqlite3` Ruby binding; it uses SQLite in-process and no external DBMS or network service.

## Quick start

From the vault root:

```sh
ruby "_System/KnowledgeGraph/bin/kg" doctor
ruby "_System/KnowledgeGraph/bin/kg" stats
ruby "_System/KnowledgeGraph/bin/kg" search "Ada"
ruby "_System/KnowledgeGraph/bin/kg" gateway capabilities
ruby "_System/KnowledgeGraph/bin/kg" gateway execute kg.entities.search '{"query":"Ada"}'
ruby "_System/KnowledgeGraph/bin/kg" workflow list
ruby "_System/KnowledgeGraph/bin/kg" scheduler list
ruby "_System/KnowledgeGraph/bin/kg" activity latest --json
ruby "_System/KnowledgeGraph/bin/kg" dataset create blood_tests --json
ruby "_System/KnowledgeGraph/bin/kg" plan compare \
  '{"description":"Reach a target","goal_type":"warm_introduction","preferences":{"target_ids":["person_<ULID>"]}}' \
  --as-of 2026-07-30
```

Execute an Intent from JSON:

```sh
ruby "_System/KnowledgeGraph/bin/kg" --run-id run_<ULID> execute \
  '{"intent":"ArchiveEntity","params":{"entity_id":"person_<ULID>"}}'
```

Use the Ruby API:

```ruby
require_relative "_System/KnowledgeGraph/lib/knowledge_graph"

kg = KnowledgeGraph::Engine.new(
  vault_root: Dir.pwd,
  run_id: "run_<26-character-ULID>",
  actor_id: "codex"
)

result = kg.execute(
  KnowledgeGraph::AddRelationship.new(
    source: "person_<ULID>",
    predicate: "knows",
    target: "person_<ULID>"
  )
)
```

## Commands

- `kg execute JSON_OR_-` executes a serialized Intent; `-` reads stdin.
- `kg validate` runs the mandatory vault validator.
- `kg doctor` checks validator, schema registry, predicate registry, and runtime.
- `kg graph [ENTITY_ID]` prints asserted edges, using inverse predicate names for inbound edges.
- `kg stats` reports canonical counts by type and status.
- `kg search QUERY` searches exact normalized identities and names/aliases.
- `kg replay AUDIT_ID` replays a successful audit event; the durable receipt makes this idempotent.
- `kg dataset create|list|describe|insert|update|delete|query|export|import|stats|explain` manages typed, versioned SQLite rows whose semantic Dataset registry entries remain canonical graph notes; every command supports `--json`.
- `kg activity latest|recent|today|yesterday|since|between|search|explain|undo|restore|diff` exposes human-oriented knowledge history; undo and restore create review-only proposals and never write the graph directly.
- `kg extract TYPE --file PATH [--dry-run]` creates a reviewable extraction proposal without changing canonical notes.
- `kg extract replay --fixture PATH` replays captured structured extraction output offline.
- `kg extract evaluate --provider replay` runs the 50-case offline golden evaluation and refreshes reports.
- `kg proposal show|export|validate PROPOSAL_ID` reviews immutable proposal artifacts.
- `kg proposal approve PROPOSAL_ID --all --actor HUMAN_ID` records explicit approval.
- `kg proposal submit PROPOSAL_ID [--dry-run]` hands approved Intents to the Engine; it never bypasses Engine gates.
- `kg intelligence relationships|opportunities|gaps|network|memory|recommendations` runs deterministic read-only analyzers.
- `kg intelligence digest|report|query|features|explain` exposes derived intelligence without writing canonical notes.
- `kg intelligence proposal [FINDING_ID]` emits an immutable proposal; `--persist` stores only proposal JSON for the existing approval workflow and still does not execute it.
- `kg goal create|list|archive` manages immutable operational goals under Git-ignored runtime state; goals are not canonical graph facts.
- `kg plan goal|scenarios|compare|simulate|trace|explain GOAL_ID_OR_JSON` runs the deterministic Candidate Generator → Scenario Evaluator → Decision Engine pipeline without graph mutation.
- `kg plan proposal GOAL_ID_OR_JSON [--persist]` converts only the decision-approved plan's generated Intents into the existing review workflow; it never executes them.
- `kg gateway capabilities` returns policy-filtered Capability Manifests and opaque invocation tokens.
- `kg gateway execute CAPABILITY_ID[@VERSION] [JSON]` resolves the CLI selector through discovery, validates the manifest contract, and executes through the Agent Gateway.
- `kg gateway policy check CAPABILITY_ID[@VERSION] [JSON]` evaluates centralized policy without invoking a handler.
- `kg gateway explain TRACE_ID` returns sanitized telemetry for one agent-owned trace.
- `kg gateway job JOB_ID [WAIT_MS]` reads an asynchronous capability job.
- `kg workflow list|run|replay|trace|cancel|jobs|resume|metrics` operates deterministic workflows and durable background jobs.
- `kg events list|publish|replay|explain|dead-letters` operates the immutable internal event stream.
- `kg scheduler list|run` inspects or runs cron-like declarative schedules.
- `kg notifications list` returns informational runtime notifications; notifications never execute actions.
- `kg cache list|explain|graph` inspects only derived computation artifacts and their event/snapshot dependencies.

Global options are `--vault`, `--run-id`, and `--actor-id`. Environment equivalents for the last two are `KG_RUN_ID` and `KG_ACTOR_ID`.

## Verification

```sh
ruby -I"_System/KnowledgeGraph/lib" -I"_System/KnowledgeGraph/test" -e 'Dir["_System/KnowledgeGraph/test/**/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
ruby "_System/Tools/test_validator.rb"
ruby "_System/Tools/validate_vault.rb"
```

See [Architecture](docs/Architecture.md), [Intent API](docs/Intent%20API.md), [Examples](docs/Examples.md), [Migration Guide](docs/Migration%20Guide.md), [AI Integration Guide](docs/AI%20Integration%20Guide.md), the [Structured Dataset Engine README](docs/Structured%20Dataset%20Engine/README.md), the [Knowledge Activity README](docs/Knowledge%20Activity/README.md), the [Knowledge Extraction README](docs/Knowledge%20Extraction/README.md), the [Knowledge Intelligence README](docs/Knowledge%20Intelligence/README.md), the [Planning & Decision Engine README](docs/Planning%20Decision%20Engine/README.md), the [Agent Platform README](docs/Agent%20Platform/README.md), and the [Event-Driven Orchestration README](docs/Event-Driven%20Orchestration/README.md).
