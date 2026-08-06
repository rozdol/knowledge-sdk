# Architecture Guide

## Product and Vault boundary

`knowledge-sdk` is the only software product. There is no companion product or required repository named `knowledge-vault`. Any Obsidian Vault may attach as an independent client and retains its own name, layout, ontology, repository, and lifecycle.

```mermaid
flowchart TB
  Clients["CLI, Ruby, Hermes, MCP, REST"] --> SDK["Standalone knowledge-sdk"]
  SDK --> Config["External config and Vault registry"]
  SDK --> Plugins["Optional plugins and validators"]
  SDK --> VaultA["Attached Obsidian Vault A"]
  SDK --> VaultB["Attached Obsidian Vault B"]
  VaultA --> MarkdownA["Canonical Markdown + ontology"]
  VaultA --> DataA[".knowledge user/runtime data"]
  VaultB --> MarkdownB["Independent Markdown + ontology"]
```

`kg attach` updates only the external registry. It never creates Vault metadata. Canonical facts remain in Markdown frontmatter. The Engine is a storage boundary, not a new canonical database: runtime receipts and the audit log contain execution metadata and can be rebuilt or removed without changing graph facts. SQLite is canonical only for structured Dataset rows whose Dataset identity remains a Markdown note.

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

## Intent classification and conversational routing

`kg chat` and `kg observe` use one SDK-owned hierarchical `KnowledgeSDK::IntentClassifier`. Phase 1 detects one semantic domain:

```text
health | finance | crm | trading | knowledge | generic
```

Phase 2 evaluates trusted plugins for the winning domain and then generic routes. A plugin registration declares its domain and route; its matcher returns `intent`, `confidence`, and `explanation`, plus optional slots. Route precedence is fixed; confidence arbitrates only among candidates on the same eligible route. Weak Dataset-template vocabulary is suppressed for read and analytical questions.

```text
Natural Language -> Intent Classifier
  -> Dataset
  -> Search
  -> Analyze
  -> Planning
  -> Proposal
  -> Specialized Graph Intents
  -> Knowledge Capture
  -> Clarification
```

Sentence type is not a domain or routing decision. Structured observations are classified before graph extraction. Medication schedules, measurements, laboratory results, body measurements, and financial rows use `kg.datasets.propose`, which creates an immutable proposal through the existing Proposal Store and validator. Ambiguous structured tables remain on the Dataset route for schema clarification and never fall through to graph extraction. `graph.observe` recognizes supported relationship-fact shapes only. Capture recognizes explicit note-like language only. No match yields clarification.

`kg chat --explain` adds a safe classifier trace containing normalized input text, semantic-domain candidates, loaded classifier plugin names, matched intent candidates, and the selected intent. It exposes no matcher objects, filesystem paths, configuration, credentials, or attached-Vault internals. Normalization is explicit UTF-8 NFC, locale-independent Unicode lowercase, and `ё`/`е` equivalence for matching; the original normalized spelling remains available to Dataset parsers so medication names retain their supplied form.

```text
structured message -> Dataset classification -> named immutable Dataset Intent
  -> existing review-only Proposal -> exact human approval
  -> existing Engine receipt/audit lifecycle -> registered Dataset handler
  -> Structured Dataset Engine SQLite transaction -> DatasetChanged
  -> existing Knowledge Activity projection
```

Named Dataset Intents contain row values and provenance but no graph attributes. Their Engine result identifies the canonical Dataset registry note; raw row values remain exclusively in SQLite. An optional graph statement such as “Alex has a medication schedule” is a separate semantic proposal and never contains the schedule rows.

## Knowledge Capture and inbox

Capture is first-class canonical Markdown and is deliberately outside both the graph ontology and the
Dataset SQLite store. The SDK validator recognizes `Captures/capture_<ULID>.md` directly, so generic
Vaults and optional profiles do not need to install a Capture schema.

```mermaid
flowchart TD
  NL["Explicit note-like natural language"] --> IC["Intent Classifier"]
  IC --> CP["knowledge.capture proposal"]
  CP --> LC["Read-only Project, Person, Company candidates"]
  LC --> AP["Exact human approval"]
  AP --> EN["Existing Engine pipeline"]
  EN --> CA["Canonical Capture in inbox"]
  CA --> RV["Review or approved link"]
  RV --> PP["Explicit promotion proposal"]
  PP --> TA["Target Intent then PromoteCapture"]
  TA --> KA["CaptureChanged and Knowledge Activity"]
```

`CreateCapture`, `ReviewCapture`, `LinkCapture`, `PromoteCapture`, and `ArchiveCapture` are independent
immutable Intents. Capture identity, kind, title, body, capture time, creator, source, and Evidence
references never change. Review state, lifecycle status, approved links, and promotion references are
mutable metadata written only by those Intents. Status progresses through `inbox`, `reviewed`,
`linked`, `promoted`, `archived`, and `deleted`; no command silently skips approval for creation or
promotion. Promotion targets existing graph/Dataset Intents and leaves the original Capture intact.

`kg.captures.search` and `kg capture search` use deterministic Unicode token scoring over kind, time,
status, title, topics, tags, and body. `kg search` includes Capture matches alongside existing Dataset
or graph results. `KnowledgeAnalysis` binds its cache to a Capture signature and returns
`capture_evidence`, theme frequencies, repeated wording groups, links to graph evidence, limitations,
and review-only plugin recommendations. Restricted Captures are excluded from cross-knowledge
analysis.

## Structured recurrence and Health schedule evolution

`KnowledgeSDK::Schedule` is a generic immutable value object, not a Health entity. Its versioned JSON
supports `daily`, `weekly`, `monthly`, `every_n_days`, `cron`, `prn`, and `custom_interval`
recurrence, multiple symbolic or local-time slots, constraints, and extension data. Medication dose,
unit, route, reason, provider, and notes stay outside this generic object.

```mermaid
flowchart TD
  NL["Natural Language"] --> HP["Health Plugin"]
  HP --> SP["Schedule Parser"]
  SP --> SO["Schedule Object"]
  SO --> PR["Proposal"]
  PR --> AP["Exact Human Approval"]
  AP --> DE["Dataset Engine via existing Engine"]
  DE --> KA["Knowledge Activity"]
  KA --> AN["Analysis"]
```

Medication schedule versions use `medschedule_<ULID>` business IDs. `medication` is indexed but not
unique. Inclusive `effective_from` and `effective_until` fields define temporal validity. An omitted
end is open-ended. Schedule replacement, dose changes, pause, resume, and discontinuation close the
applicable interval and retain prior versions; they do not delete history. A paused version carries
`active: false`, while active course versions carry `active: true`.

Legacy medication tables are a bounded exception to additive-only Dataset migration. When the
trusted planner detects the exact `effective_on`/`schedule` legacy shape, it emits an
`UpgradeDatasetSchema` prerequisite with `migration_id: medication_schedules_v2`. After exact
approval, the Dataset Engine rebuilds the physical table inside one SQLite transaction, transforms
each row to structured JSON, preserves logical row/provenance IDs, verifies the row count, records a
schema version and Dataset activity, and then executes the dependent observation. No arbitrary
transform is accepted from an attached Vault.

## Autonomous Dataset lifecycle

Dataset absence and additive schema drift are proposal prerequisites, not terminal blockers:

```text
classified Dataset observation
  -> AutonomousRegistry inspects graph registry + SQLite schema history
  -> missing: CreateDatasetProposal / immutable CreateDataset
  -> mismatch: DatasetSchemaUpgradeProposal / immutable UpgradeDatasetSchema
  -> original Dataset row Intent depends on lifecycle Intent
  -> exact human approval of immutable Intent IDs
  -> dependency-ordered Proposal Submitter
  -> existing Engine validation/audit/receipt boundary
  -> lifecycle handler creates or additively migrates Dataset
  -> original row Intent retries through Engine
  -> DatasetChanged + Knowledge Activity
```

Schema upgrade Intents bind the observed schema version and complete additive definition. Execution rechecks the version before mutation. New columns are optional; destructive removal, reorder, rename, retype, and constraint changes remain rejected. The planner performs no write and never treats attached-Vault content as executable schema policy.

## Smart Dataset templates and provisioning

The Dataset Template Registry is trusted SDK/plugin code above the existing lifecycle planner. A template is immutable and versioned and declares a complete `Definition`, parser, validation and units, recommended analyzers, default visualizations, privacy level, review-only recommendation rules, and future adapter names. Template registration never reads executable behavior from an attached Vault or imported source.

```mermaid
flowchart TD
  E["Incoming Evidence: PDF/OCR, CSV, Excel, text, transcript, email"] --> C["Intent Classifier"]
  C --> T["Dataset Template Registry"]
  T --> S["Template + confidence + reason"]
  S --> P["CreateDatasetProposal and row Intent DAG"]
  P --> A["Exact human approval"]
  A --> D["Existing Dataset lifecycle handler"]
  D --> R["Retry approved row Intents"]
  R --> Q["SQLite"]
  Q --> K["Knowledge Activity"]
  K --> X["kg analyze / template semantics plugin"]
```

Selection and parsing are read-only. A missing Dataset adds the existing `CreateDataset` prerequisite; an existing additive mismatch adds the existing `UpgradeDatasetSchema` prerequisite. Each parsed `InsertDatasetRow` depends on that prerequisite. Approval and submission remain separate, and no Dataset or row exists before submission.

Blood tests use a normalized row model. Analyte names are values, never physical columns. The model records `test_date`, `panel`, `analyte`, `value`, `unit`, numeric and textual reference intervals, `flag`, `specimen`, `laboratory`, and comments. Compatibility aliases retain Phase 13/14 approved Intent and query replay without hardcoding biomarker names.

The complete normalized source rendition is stored locally as immutable Evidence with the original artifact URI. Dataset rows carry `evidence_id`, `source_uri`, `source_filename`, `source_page`, and `source_span` alongside observation, proposal, approval, and Intent IDs. The Dataset registry note contains only semantic/template metadata; raw measurements remain in SQLite and source Evidence.

## Cross-knowledge analysis pipeline

`kg analyze` is a derived read pipeline that composes stable subsystems. It is not a second Intelligence, Planning, Activity, or Dataset implementation.

```mermaid
flowchart LR
  Q["Question"] --> IC["IntentClassifier / Analyze Intent"]
  IC --> AX["KnowledgeAnalysis context"]
  AX --> GS["Graph snapshot"]
  AX --> CP["Policy-visible Captures + signature"]
  AX --> DS["Dataset queries + statistics"]
  AX --> KA["Knowledge Activity"]
  AX --> KI["Knowledge Intelligence"]
  AX --> PS["Planning signals"]
  AX --> EB["Event history"]
  GS --> AP["Installed analysis plugins"]
  CP --> AP
  DS --> AP
  KA --> AP
  KI --> AP
  PS --> AP
  EB --> AP
  AP --> CE["Deterministic Correlation Engine"]
  CE --> EX["Explanation, confidence, windows, limitations"]
  EX --> RP["Optional non-executable Recommendation Proposal"]
  EX --> KC["Derived Knowledge Cache"]
```

The Correlation Engine provides stable time alignment, windowing, cross-Dataset pairing, trend detection, event comparison, Pearson association, and confidence estimation. It contains no model call or hidden reasoning. Every factor says `causal: false`. Recommendation candidates become review-only Planning candidate objects and use the existing Decision Engine policy for stable ranking; they contain zero generated Intents and remain non-executable until a later concrete Intent proposal is explicitly approved.

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

## Event-driven orchestration pipeline

Phase 9 coordinates the stable components without moving planning, decision making, approval, or execution into the Orchestrator:

```text
immutable Event -> versioned Event Bus -> declarative Trigger
  -> deterministic Workflow DAG -> durable Job
  -> policy-filtered Agent Gateway capability
  -> derived Knowledge Cache artifact / notification / review-only proposal
  -> explicit human approval -> existing Engine
```

Workflow definitions cannot contain `kg.proposals.submit`, and runtime invocation rejects every graph-write or existing-approval capability. A workflow may produce a review-only proposal, but the Orchestrator cannot approve or submit it.

The Knowledge Cache is not a fact cache and not a graph cache. It stores only derived, reproducible outputs such as analyzer results, plans, reports, briefings, digests, recommendations, and workflow outputs. Every artifact records its producing capability version, immutable graph snapshot digest, originating event IDs, invalidating event types, and optional entity scope. A new event marks only affected artifacts stale; a snapshot mismatch prevents reuse even before stale marking.

## Knowledge Activity projection

Phase 10A presents successful Engine changes as human-oriented activities. It joins existing audit receipts, Event Bus history, proposal/approval/submission receipts, and the current immutable graph snapshot at read time. Activity IDs are derived from audit IDs, so the projection has no store of its own.

Undo and restore perform no graph write. They derive lossless existing Intents from audit/replay history, preserve exact audit evidence and confidence fields in a fresh immutable proposal, and stop at `awaiting_approval`. Only the existing approval and Proposal Submitter path may later reach the Engine.

## Modules

- `knowledge_sdk/` owns external configuration, generic Vault attachment/discovery, lifecycle commands, optional profile discovery, and extraction migration.
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
- `knowledge_orchestration/` owns immutable events, the internal bus and dead-letter queue, trigger and workflow DSL, dependency graph, derived-artifact Knowledge Cache, durable jobs, cron scheduler, notifications, replay, and sanitized timelines. It invokes existing components only through Agent Gateway capabilities.
- `knowledge_activity/` owns the read-time Activity projection, human summaries, temporal filtering/search/diff, privacy redaction, explainability joins, and review-only undo/restore proposal adaptation. It has no canonical writer or Activity store.
- `knowledge_sdk/intent_classifier.rb` owns semantic-domain detection, fixed route precedence, domain-scoped plugin confidence arbitration, and the immutable classification contract used by chat and observation.
- `knowledge_capture/` owns the canonical Capture value, SDK-owned store/validator contract, Engine handlers, inbox CLI, explicit classifier, read-only link candidates, search, promotion proposal planning, plugin registry, and analysis contribution. It does not mutate linked entities or approve proposals.
- `knowledge_sdk/schedule.rb` owns the generic immutable recurrence value and interval-overlap semantics; it has no writer or medication dependency.
- `structured_dataset/routing.rb` owns Dataset classifiers, named Dataset Intent proposal construction, and the handlers registered on the existing Engine. It never invokes graph extraction for row data.
- `structured_dataset/medication_schedules.rb` owns trusted Health schedule row evolution and the one versioned legacy-table transform.
- `structured_dataset/evolution.rb` owns read-only autonomous lifecycle planning and emits `CreateDataset` or `UpgradeDatasetSchema` prerequisites. Only the approval-gated Dataset handler executes them.
- `structured_dataset/templates.rb` owns immutable versioned template definitions, trusted plugin registration, deterministic selection, built-in parsers, the built-in catalogue, and safe classifier integration. It has no writer or approval authority.
- `knowledge_analysis/` owns the cross-subsystem analysis context, deterministic Correlation Engine, analysis plugin registry, response aggregation, derived caching, recommendation envelopes, and `kg analyze` CLI. It never writes graph facts or Dataset rows.

## Transaction guarantees

Files are staged in memory. Before commit, the Engine re-reads every affected live file and compares its SHA-256 fingerprint with the inspected snapshot. A mismatch aborts without restoring stale content. Commit uses same-directory temporary files and rename; any mid-commit exception restores all pre-write snapshots. A vault-specific process lock serializes Engine writers.

The candidate validator receives copies of all validation-relevant Markdown and the staged overlay. Validators are SDK/plugin resources, never executable files copied from an attached Vault. Invalid changes never touch the live Vault.

## YAML and bodies

The writer accepts only scalars and flat scalar lists, emits canonical property order, quotes strings (therefore every wiki link), and rejects nested YAML. Update operations preserve unknown keys and all body bytes. Body-writing capabilities operate only in named `AGENT-MANAGED` sections; merge and rename may perform verified wiki-link target rewrites required for graph consistency.

## Relationships

One Relationship note is one canonical edge. Symmetric predicates sort endpoints by immutable ID. Inverses are registry/query semantics, so the Engine does not create a mirrored second edge. `RemoveRelationship` retracts rather than deletes. `ReplaceRelationship` retracts the original and asserts its replacement in one transaction.

## Identity and merge

Exact IDs and merged redirects resolve first, followed by strong normalized identifiers. Names and aliases generate candidates but never authorize a merge. Person merge/split requires `human_approved: true`. Merge preserves the losing body in its redirect stub, rewrites verified links and sibling IDs, reorders symmetric roles, and retracts duplicate edge signatures. Conflicting non-policy scalar facts abort the merge.

## Idempotency and audit

An Intent fingerprint is SHA-256 over canonical JSON serialization. A successful command stages `.knowledge/runtime/receipts/<fingerprint>.json` in the same transaction as graph changes. Re-execution validates the Vault and returns the stored result with `replayed: true`.

Each attempt appends a local JSONL audit event containing timestamp, Intent payload, affected IDs, result, duration, rollback flag, replay flag, run ID, and actor ID. Runtime data lives under `.knowledge/runtime/`, is local and Git-ignored by the bundled migration guidance, and is operational history rather than a source of canonical facts. Dataset rows live separately at `.knowledge/datasets.sqlite3`.
