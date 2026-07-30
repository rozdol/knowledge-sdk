# Agent Platform Migration Guide

## Integration rule

New agents and interfaces must use the Agent Platform. Existing Engine, Extraction, and Intelligence CLIs remain available for trusted local administration and regression compatibility, but an integration must not import their internal classes directly.

## Migrating a direct caller

1. Inventory every direct GraphReader, Intelligence, Extraction, ProposalStore, or Engine call.
2. Map it to a core manifest. If none fits, design and version a new manifest before implementation.
3. Create an explicit `AgentIdentity` and minimum permissions.
4. Replace static tool lists with `Gateway#discover`.
5. Replace method-name dispatch with the returned opaque invocation token.
6. Move conversational pointers into an expiring immutable session using IDs only.
7. Handle typed errors and asynchronous `accepted` responses.
8. Render reasoning fields and warnings.
9. Confirm no output exposes paths, Markdown, YAML, classes, or Vault layout.
10. Add compatibility and golden tests before removing the direct integration.

## CLI compatibility

`kg gateway execute CAPABILITY_ID[@VERSION] JSON` is intended for humans and scripts. The textual selector is resolved against current discovery, then the adapter invokes the opaque token. Scripts that need strict stability should include `@VERSION` and validate the returned manifest digest.

## Write migration

Do not wrap direct `Engine#execute` as an arbitrary write capability. Source ingestion uses `kg.extraction.extract_source`; deterministic recommendations use `kg.proposals.create`; both stop at immutable proposals. A human approves through the existing approval pipeline. Only `kg.proposals.submit` may hand that exact approved proposal to `ProposalSubmitter` and the Engine.

## Rollback

Removing Phase 7 code does not require a graph migration because manifests, sessions, jobs, telemetry, and proposal artifacts are not canonical graph facts. Canonical Markdown and Engine receipts remain governed by the earlier layers.
