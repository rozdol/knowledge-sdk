# Developer Guide

## Source layout

- `lib/agent_platform/manifest.rb`, `registry.rb`, and `schema_validator.rb` define public contracts.
- `models.rb`, `session.rb`, and `policy.rb` define immutable request context and authorization.
- `gateway.rb`, `security.rb`, `telemetry.rb`, and `jobs.rb` own execution concerns.
- `services.rb` and `handlers.rb` adapt stable Phase 4–6 APIs; they do not reimplement those layers.
- `adapters/` contains transport mapping only.
- `config/agent_platform/manifests/` is the public core contract catalog.
- `test/agent_platform/` contains Phase 7 tests and synthetic fixtures.

## Adding core behavior

Start with a manifest. Decide typed inputs/outputs, effects, timeout, idempotency, permissions, risk, approval, errors, reasoning fields, examples, and version compatibility. Then add a handler over `GraphReader`, `GraphSnapshot`, Knowledge Intelligence, Knowledge Extraction, or the proposal pipeline. Register it in `DefaultHandlers` and add focused and golden tests.

Handlers return only public domain projections. Use immutable entity IDs and safe evidence references. Never return `path`, `relative_path`, `changed_paths`, raw Markdown, Vault roots, internal classes, handlers, or storage adapters; `SecurityGuard` fails the request if these appear.

Reasoning manifests must return `why`. Include confidence, evidence, and graph path where supported. Empty results still need an honest explanation and confidence semantics.

## Tests

Run Phase 7 only:

```sh
ruby -I"lib" -I"test" \
  -e 'Dir["test/agent_platform/**/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
```

Run all regressions before committing:

```sh
ruby -I"lib" -I"test" \
  -e 'Dir["test/**/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
ruby test/validator_test.rb
ruby "validators/personal_crm/validate_vault.rb"
```

Use `AGENT_PLATFORM_FULL_PERFORMANCE=1` for the 5,000-capability registry fixture. All source-ingestion fixtures are hostile data and must remain synthetic.
