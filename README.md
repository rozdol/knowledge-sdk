# Knowledge Graph Engine SDK

The Knowledge Graph Engine is the only automated write interface for canonical vault notes. Callers submit immutable Intents; the Engine resolves identities, stages Markdown changes, validates a candidate vault, commits atomically, and records replay metadata. Markdown remains the only canonical source of facts.

The package uses the Ruby standard library only and runs on the vault's bundled Ruby 2.6 or newer.

## Quick start

From the vault root:

```sh
ruby "_System/KnowledgeGraph/bin/kg" doctor
ruby "_System/KnowledgeGraph/bin/kg" stats
ruby "_System/KnowledgeGraph/bin/kg" search "Ada"
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

Global options are `--vault`, `--run-id`, and `--actor-id`. Environment equivalents for the last two are `KG_RUN_ID` and `KG_ACTOR_ID`.

## Verification

```sh
ruby -I"_System/KnowledgeGraph/lib" -e 'Dir["_System/KnowledgeGraph/test/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
ruby "_System/Tools/test_validator.rb"
ruby "_System/Tools/validate_vault.rb"
```

See [Architecture](docs/Architecture.md), [Intent API](docs/Intent%20API.md), [Examples](docs/Examples.md), [Migration Guide](docs/Migration%20Guide.md), and [AI Integration Guide](docs/AI%20Integration%20Guide.md).
