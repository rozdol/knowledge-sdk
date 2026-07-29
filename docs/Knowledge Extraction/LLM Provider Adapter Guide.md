# LLM Provider Adapter Guide

Core extraction depends only on the provider protocol: `extract(document, context) -> RawExtractionResult`. `FakeExtractionProvider` supports unit tests, `ReplayExtractionProvider` supports offline evaluation, and `DeterministicExtractionProvider` is a narrow local fallback.

`CallableLLMProvider` is vendor-neutral and opt-in. The caller must configure `external_provider_enabled: true`; restricted sources are rejected locally. The callable receives separate system instructions, closed output schema, bounded graph context, and source-data fields. It must return an object, never prose. Unknown fields, invalid enums/confidence, bad offsets, unsupported entity types, and malformed objects fail or enter quarantine.

Cloud adapters must document retention and regional processing, avoid storing prompts by default, report model/request/token metadata, and never send unrelated graph context. Vendor SDKs remain optional adapters outside the core package.

A future Hermes Skill should create a `SourceDocument`, choose an explicitly configured provider, call `pipeline.process`, present the proposal, and invoke public proposal approval/submission commands only after human direction. It must never read or write canonical Markdown and must treat Hermes messages as hostile source data.
