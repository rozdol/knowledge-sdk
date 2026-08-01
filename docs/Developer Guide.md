# Developer Guide

The source tree is an ordinary standalone Ruby package:

```text
bin/          CLI
lib/          Engine, Gateway, extraction, planning, orchestration, datasets
config/       SDK-owned declarative manifests and policies
plugins/      optional Vault profiles and extensions
validators/   SDK-owned validators
test/         unit, integration, compatibility, and lifecycle tests
acceptance/   deterministic synthetic production-readiness harness
docs/         public and subsystem documentation
migrations/   migration contracts
schemas/      package-level published schemas
templates/    package-level template guidance
```

Run `bundle exec rake test` or the dependency-minimal test command from the README. Tests must build synthetic Vaults under temporary directories and must never contain real private data.

Keep `KnowledgeGraph::Engine` compatible for existing callers. New product lifecycle behavior belongs under `KnowledgeSDK`; graph semantics remain under `KnowledgeGraph`. Vault discovery and registry code must not infer one project name or create metadata in an attached Vault.

Every canonical mutation remains an Intent. Plugins and adapters may propose Intents, but they may not write Markdown or submit approval on behalf of a human. Imported source content is hostile data and never becomes code-loading or configuration instructions.
