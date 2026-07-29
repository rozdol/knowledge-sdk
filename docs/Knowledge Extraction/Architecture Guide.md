# Knowledge Extraction Architecture Guide

## Modules

The package entry point is `_System/KnowledgeGraph/lib/knowledge_extraction.rb`.

- `sources.rb`, `dates.rb`: source contracts, normalization, language and temporal handling.
- `evidence.rb`, `facts.rb`: immutable source-independent evidence, mention, scalar, and fact models.
- `providers.rb`, `structured_output.rb`: fake/replay/deterministic providers, optional callable LLM adapter, and hostile-output validation.
- `resolution.rb`, `knowledge_graph/graph_reader.rb`: candidate retrieval, scoring, conflict detection, and conservative outcomes.
- `planning.rb`, `proposal.rb`: existing Engine Intent mapping, provenance, dependency graph, risk, and canonical proposal JSON.
- `store.rb`, `submission.rb`: ignored Runtime artifacts, approval receipts, validation, and explicit Engine handoff.
- `evaluation.rb`: golden runner, metrics, calibration, and Markdown reports.
- `cli.rb`: extraction and proposal commands delegated from the existing `kg` CLI.

## State and failure semantics

Proposal states distinguish `resolution_required`, `planned`, `awaiting_approval`, `partially_rejected`, and `failed`; extraction is never reported as a graph update. A provider failure produces neither a partial proposal nor a graph change. Malformed items are quarantined with stage/reason metadata while structurally hostile envelopes fail closed.

Each proposal dependency group uses one existing immutable Intent per Engine transaction. Creates execute before dependent edges. If a later group fails, that Intent rolls back through the Engine and later groups stop; already completed independent groups remain explicit in the submission receipt. This is intentionally documented instead of implying whole-proposal atomicity that Phase 4 does not expose.

## Determinism and duplicates

Normalized content hashes use SHA-256. Source IDs use source type plus external ID, URI, or content hash. Fact, evidence, mention, planned-Intent, entity, and proposal IDs are deterministic for fixed inputs. Stage durations are logged but excluded from canonical proposal JSON.

Runtime source receipts classify `new`, `exact_duplicate`, `exact_content_duplicate`, and `revision`. Duplicate sources are returned explicitly and never silently discarded.

## Observability

Structured events contain source/proposal IDs, types, provider/model/prompt, stage durations, fact counts, ambiguity counts, proposed/blocked Intent counts, token usage, and error metadata. Raw source text is not logged.
