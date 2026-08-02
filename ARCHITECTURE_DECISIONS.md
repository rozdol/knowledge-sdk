# Architecture Decisions

> ADR-lite record for the standalone `knowledge-sdk` product. For implementation detail, see `docs/Architecture.md`.

| Field | Value |
|---|---|
| Status | Living product rationale |
| SDK version | `14.0.0` |
| Baseline extraction revision | `8dba780` |
| Updated | `2026-08-02` |

Accepted decisions are normative until superseded by a later ADR and a compatible implementation or migration. Decisions belonging to a particular Vault, ontology, or user's knowledge model stay in that Vault.

## Decision index

| ID | Decision | Status |
|---|---|---|
| SDK-ADR-001 | Ship one standalone SDK; treat arbitrary Obsidian Vaults as independent clients | Accepted |
| SDK-ADR-002 | Keep Vault attachment metadata in external configuration | Accepted |
| SDK-ADR-003 | Keep Markdown frontmatter canonical for graph facts | Accepted with boundary |
| SDK-ADR-004 | Route canonical mutations through immutable Intents and one Engine pipeline | Accepted |
| SDK-ADR-005 | Validate a staged candidate and use optimistic, atomic filesystem commits | Accepted |
| SDK-ADR-006 | Separate extraction, planning, review, approval, and execution authority | Accepted |
| SDK-ADR-007 | Expose agent capabilities through manifests, opaque tokens, and centralized policy | Accepted |
| SDK-ADR-008 | Keep intelligence and planning deterministic and noncanonical | Accepted |
| SDK-ADR-009 | Prevent orchestration from approving or directly executing graph writes | Accepted |
| SDK-ADR-010 | Make profiles and plugins explicit SDK-owned opt-ins | Accepted |
| SDK-ADR-011 | Store operational state and structured rows as bounded local data | Accepted with boundary |
| SDK-ADR-012 | Preserve the `KnowledgeGraph` API while evolving lifecycle under `KnowledgeSDK` | Accepted |
| SDK-ADR-013 | Prefer a local-first, Ruby 2.6-compatible, standard-library-heavy package | Accepted with boundary |
| SDK-ADR-014 | Make extraction migrations inspectable, backed up, and collision-safe | Accepted |
| SDK-ADR-015 | Never execute validators or instructions discovered in attached Vault content | Accepted |
| SDK-ADR-016 | Use only synthetic private-data-free fixtures for package tests | Accepted |
| SDK-ADR-017 | Make Dataset registration and additive schema evolution approval-gated lifecycle Intents | Accepted |
| SDK-ADR-018 | Provide deterministic plugin-based analysis across graph, Dataset, and derived evidence | Accepted |
| SDK-ADR-019 | Keep analytical recommendations non-executable until a separate concrete Intent proposal | Accepted |
| SDK-ADR-020 | Classify semantic domain before intent and make graph observation the last resort | Accepted |
| SDK-ADR-021 | Represent recurrence generically and medication history as immutable effective intervals | Accepted |

## SDK-ADR-001 — One standalone SDK and arbitrary Vault clients

**Decision.** `knowledge-sdk` is the software product. Any Obsidian Vault may attach as a client while retaining its own name, repository, layout, ontology, and lifecycle. The SDK does not require or create a companion project named `knowledge-vault`.

**Consequences.** Public APIs accept an explicit or resolved Vault root. Product code, tests, migrations, and package documentation live in this repository. Vault-local knowledge and operating rules remain in each Vault.

## SDK-ADR-002 — External attachment registry

**Decision.** `kg attach` stores absolute paths, display names, optional profiles, and active selection in external SDK configuration. It writes nothing into the Vault. `kg detach` removes only that registry entry.

**Consequences.** Attachment is reversible and cannot impose `.vault.yml` or another SDK metadata convention. Resolution order is `--vault`, `KG_VAULT`, upward discovery, then the active registry entry.

## SDK-ADR-003 — Markdown as canonical graph storage

**Decision.** Schema-valid Markdown frontmatter in an attached Vault is canonical for graph facts. Receipts, audit events, caches, projections, and reasoning output are operational or derived artifacts.

**Boundary.** Structured Dataset rows may be canonical within the Dataset subsystem's SQLite store, while Dataset identity and graph semantics remain in Markdown.

## SDK-ADR-004 — Immutable Intents and one writer

**Decision.** Every canonical graph mutation is represented by an immutable Intent and reaches `Engine#execute`. CLI, Gateway, adapters, proposals, and plugins may not create alternate write paths.

**Consequences.** Idempotency fingerprints, approval metadata, auditing, and replay use one serialization contract. Extensions propose or dispatch supported Intents rather than editing YAML or Markdown directly.

## SDK-ADR-005 — Candidate validation and atomic commit

**Decision.** The Engine stages changes, validates an isolated candidate Vault with SDK/plugin validators, checks live-file fingerprints immediately before commit, and replaces files atomically under a Vault-specific writer lock.

**Consequences.** Invalid or concurrently changed content aborts before replacement. Rollback restores inspected snapshots only for failures within the controlled commit, never over newer external edits.

## SDK-ADR-006 — Separate reasoning from authority

**Decision.** Extraction, intelligence, planning, activity reversal, and automation may create evidence-backed outputs or immutable proposals. Review, exact approval, and Engine execution remain separate operations.

**Consequences.** “Recommended,” “decision-approved,” or “workflow-complete” never means human-approved. Generated Intents are not submitted automatically by default.

## SDK-ADR-007 — Manifest-first Agent Gateway

**Decision.** Agent clients discover policy-filtered manifests and invoke capabilities with opaque tokens. Central policy, exact approval checks, input/output validation, and leak guards live at the Gateway boundary.

**Consequences.** Transport capability strings are selectors, not execution authority. Hermes, MCP, REST-style, and future adapters remain thin and cannot dispatch private handlers directly.

## SDK-ADR-008 — Deterministic noncanonical reasoning

**Decision.** Intelligence, scenario evaluation, and planning are bound to immutable graph snapshots and explicit dates/policies. Their outputs are derived and do not become facts without a later approved Intent.

**Consequences.** Equal inputs produce stable canonical results. Caches must record snapshot and capability dependencies and may be discarded without changing knowledge.

## SDK-ADR-009 — Constrained orchestration

**Decision.** Workflows coordinate immutable events, triggers, jobs, read capabilities, derived artifacts, notifications, and review-only proposals. They cannot approve or submit graph writes.

**Consequences.** Orchestration improves repeatability without becoming an autonomous authority layer. Runtime dispatch rejects graph-write and approval capabilities.

## SDK-ADR-010 — Explicit SDK-owned plugins

**Decision.** Profiles and plugins are installed only through an explicit user action. Executable validators and capability implementations come from trusted SDK/plugin resources, not arbitrary attached-Vault files.

**Consequences.** Plain `kg init` creates a minimal Vault. Plugin installation must detect conflicts and refuse unsafe replacement. A profile never renames or assumes ownership of a Vault.

## SDK-ADR-011 — Bounded local operational data

**Decision.** Receipts, audit state, jobs, caches, and similar runtime artifacts live under `.knowledge/runtime/`; structured rows default to `.knowledge/datasets.sqlite3`.

**Boundary.** These paths are user data locations, not embedded SDK installations. Operational data is noncanonical for graph facts, and caches/projections must be rebuildable.

## SDK-ADR-012 — Compatibility namespace

**Decision.** Existing graph callers may continue using `KnowledgeGraph::Engine`. New configuration, discovery, registry, lifecycle, plugin, and migration behavior belongs under `KnowledgeSDK`.

**Consequences.** Extraction into a standalone product does not force an immediate caller rewrite. Breaking public contracts require versioning and migration guidance.

## SDK-ADR-013 — Local-first Ruby package

**Decision.** Support Ruby 2.6 or newer and prefer standard-library components where practical. SQLite is the explicit runtime dependency for structured datasets.

**Boundary.** Hosted infrastructure and additional dependencies may be introduced only for a concrete capability with documented deployment and compatibility costs.

## SDK-ADR-014 — Safe extraction migration

**Decision.** Migration from an embedded SDK performs preflight checks, creates an external backup and manifest with fingerprints, moves known paths deterministically, and refuses rollback collisions or changed destinations.

**Consequences.** The original Vault keeps its identity and Git history. A pre-migration Vault commit remains the full repository rollback boundary.

## SDK-ADR-015 — Attached content is data, not code

**Decision.** Imported messages, web pages, notes, templates, and other Vault content are untrusted data. The SDK never treats instructions found there as agent policy, configuration, validators, or executable plugins.

**Consequences.** Source ingestion retains evidence and confidence while ignoring embedded instructions. Validator and plugin lookup is package-registry based.

## SDK-ADR-016 — Synthetic verification data

**Decision.** Unit, integration, compatibility, migration, and acceptance fixtures use synthetic data and temporary Vaults. Real private Vault content is not copied into the package or its history.

**Consequences.** Tests remain redistributable and privacy-safe. Validation against a real Vault is an explicit user-scoped check, not a package fixture-generation shortcut.

## SDK-ADR-017 — Proposal-driven Dataset lifecycle

**Decision.** Missing Datasets and additive schema mismatches produce immutable `CreateDataset` or `UpgradeDatasetSchema` prerequisites in the same dependency-ordered proposal as the original row. Exact approval and the existing Proposal Submitter execute the lifecycle prerequisite through the Engine before retrying the row.

**Consequences.** Conversational users never need to run a manual Dataset create command. Dataset planning stays read-only. Schema execution records the observed version, refuses concurrent drift, appends optional columns only, emits Dataset activity, and preserves all existing approval, receipt, audit, and event boundaries. Trusted direct Ruby lifecycle methods remain compatibility primitives, not conversational authority.

## SDK-ADR-018 — Deterministic cross-knowledge analysis

**Decision.** `kg analyze` composes graph snapshots, Dataset queries/statistics, Knowledge Activity, Knowledge Intelligence findings, planning signals, event history, and Knowledge Cache through installed deterministic analysis plugins and one pure Correlation Engine.

**Consequences.** Analysis does not duplicate canonical storage or subsystem semantics. Equal snapshot, Dataset signature, question, window, and plugin versions produce the same answer. Responses identify datasets, graph evidence, time windows, confidence, and limitations. Correlation and temporal order always remain noncausal hints unless independent evidence explicitly supports a stronger claim.

## SDK-ADR-019 — Recommendation authority boundary

**Decision.** Analytical recommendations are derived, noncanonical, and non-executable. The optional recommendation proposal is a review envelope with no executable Intent. A recommendation becomes actionable only through a later concrete immutable Intent proposal, exact human approval, and Engine submission.

**Consequences.** Analysis cannot grant itself execution authority. `RecommendationGenerated` may appear in Knowledge Activity, while approval and execution remain visibly separate operations.

## SDK-ADR-020 — Hierarchical intent classification

**Decision.** Conversational routing first detects one semantic domain from `health`, `finance`, `crm`, `trading`, `knowledge`, and `generic`. It then invokes all trusted classifier plugins registered for the winning domain and selects the highest-confidence `intent`, `confidence`, and `explanation` result. If none matches, generic analysis, planning, proposal, Dataset-table, and search plugins run. The generic `graph.observe` classifier occupies a separate last-resort tier and cannot compete as a default route.

**Consequences.** Declarative versus interrogative form is no longer the primary routing signal. Structured medication schedules, measurements, laboratory results, body metrics, and similar observations reach domain plugins before graph extraction, including supported English, Russian, and Greek forms. Domain and classifier plugins remain deterministic SDK-owned code; imported or attached-Vault content cannot register executable matchers.

## SDK-ADR-021 — Generic recurrence and immutable medication intervals

**Decision.** Recurrence is an immutable `KnowledgeSDK::Schedule` value object with versioned JSON,
generic frequency and time-slot fields, optional recurrence-specific fields, constraints, and
extensions. Medication schedule rows use immutable schedule IDs and inclusive
`effective_from`/`effective_until` intervals. Medication is indexed but not unique; schedule
evolution closes prior versions and appends successors rather than deleting history.

**Consequences.** Multiple daily doses and overlapping future/temporary schedule records are valid.
The Health plugin supplies medication-specific dose, route, provider, and reason fields outside the
generic recurrence object. Pause and resume are represented as inactive and active interval
versions. Analysis and reminder consumers read typed recurrence data without NLP. Legacy
`schedule`/`effective_on` storage is upgraded only by the trusted `medication_schedules_v2`
copy-and-verify transform selected by an exact-approved `UpgradeDatasetSchema` Intent; arbitrary
schema replacement remains unsupported.
