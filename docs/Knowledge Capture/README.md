# Knowledge Capture

Knowledge Capture is the first-class inbox for content a user explicitly wants to remember before
deciding where it belongs. It is not a generic fallback, graph entity extractor, Dataset row store,
or staging database.

## Canonical contract

Each Capture is one Markdown file at `Captures/capture_<ULID>.md`. The SDK validates this format
without requiring a Vault ontology schema. The frontmatter is flat and contains immutable identity
and content metadata plus lifecycle metadata; the body is ordinary Markdown.

```yaml
---
id: "capture_<ULID>"
capture_id: "capture_<ULID>"
type: "capture"
schema_version: 1
kind: "idea"
title: "Automate client reports"
captured_at: "2026-08-06T10:00:00Z"
importance: "normal"
status: "inbox"
review_state: "unreviewed"
topics: []
tags:
  - "knowledge/capture"
  - "capture/idea"
language: "en"
related_entities: []
related_projects: []
related_contacts: []
evidence:
  - "evidence_<ULID>"
source: "telegram"
sensitivity: "private"
---
Automate client reports.
```

Supported kinds are `thought`, `idea`, `note`, `question`, `lesson`, `decision`, `observation`,
`bookmark`, `reference`, `quote`, and `hypothesis`. Kind is metadata; no separate entity type or
folder is created. The ID, kind, title, Markdown body, capture time, creator, original source, and
Evidence references are immutable.

## Routing and clarification

`kg chat` is the public natural-language entry point. The route order is:

```text
Dataset -> Search -> Analyze -> Planning -> Proposal
  -> Specialized Graph -> Capture -> Clarification
```

Capture requires an explicit note-like signal such as “I have an idea…”, “Запомни мысль…”,
“Запиши…”, “Я понял что…”, or “Έχω μια ιδέα…”. Supported graph facts stay on `graph.observe`;
structured measurements stay on Dataset; questions about existing Captures stay on search. Messages
such as “Сделай это” and “Нужно разобраться” clarify and write nothing.

An eligible message creates a local review artifact, not a Capture:

```text
explicit Capture language -> immutable source Evidence
  -> CreateCapture proposal (+ optional dependent LinkCapture)
  -> exact approval of planned Intent IDs
  -> Proposal Submitter -> Engine -> candidate validation -> atomic commit
  -> CaptureChanged -> Knowledge Activity
```

## Automatic linking

The linker performs a read-only scan of policy-visible canonical names and aliases. A Project mention
becomes a Project candidate, a Person mention becomes a Contact candidate, and an Organization
mention becomes an Entity candidate. Trusted plugins may add candidates. Candidates appear in the
proposal metadata and human confirmation; no target is mutated. Only an exactly approved
`LinkCapture` writes Capture link metadata.

## Inbox and lifecycle

Every Capture begins with `status: inbox` and `review_state: unreviewed`.

```text
inbox -> reviewed -> linked -> promoted -> archived -> deleted
```

The status is monotonic for ordinary commands. Review and link do not change the immutable body.
Archive uses `ArchiveCapture` through the Engine. Deletion is a reserved terminal state; Version 16
does not expose a delete command.

```sh
kg inbox
kg capture list [--status inbox] [--kind idea]
kg capture show "Automate client reports"
kg capture latest
kg capture search "What ideas do I have about AI?"
kg capture review "Automate client reports"
kg capture archive "Automate client reports"
```

Human output omits immutable Capture IDs. Add `--ids` only when an ID is explicitly needed; add
`--json` for a stable machine response.

## Promotion

Promotion always creates a proposal. An existing canonical target may be supplied with `--target`.
Built-in planning can create Project, Goal, Decision, generic Graph Entity, Dataset, Relationship, or
Meeting targets when their required attributes and installed schema are available. Trusted plugins
may supply domain-specific promotion rules.

```sh
kg capture promote "Automate client reports" --to project --target project_<ULID>
kg proposal approve proposal_<ULID> --all --actor-id human:owner
kg proposal submit proposal_<ULID>
```

For a new target, the proposal orders the target Intent before `PromoteCapture`. A failed target stops
the lifecycle change. Successful promotion records its target on the Capture but preserves the
original Markdown body and Evidence.

## Search and analysis

Capture search supports kind, status, time, title, topics, tags, and body. It recognizes questions
such as “What notes did I write last week?”, “What trading lessons have I recorded?”, “What questions
are still unanswered?”, and “What have I recently captured?”. `kg search` adds Capture matches to its
existing Dataset or graph response.

`kg analyze` loads policy-visible Captures into the same deterministic context as Graph, Dataset,
Activity, Intelligence, Planning, events, and cache state. Responses include `capture_evidence`, a
Capture signature, common themes, exact repeated wording groups, graph evidence from approved links,
and limitations. Restricted Capture text is never included. Association remains noncausal.

## Plugin API

Trusted installed code registers one named object with one or more of these methods:

```ruby
plugin = MyCapturePlugin.new
KnowledgeCapture.registry.register(plugin)

# Optional plugin methods:
# enrich_capture(attributes) -> Hash
# extract_capture_topics(text) -> Array<String>
# capture_link_candidates(text, context) -> Array<Hash>
# build_capture_promotion(capture, kind, options) -> Array<KnowledgeGraph::Intent> or nil
# capture_recommendations(capture) -> Array<String>
```

Plugin inputs are immutable projections. Plugins get no Engine or approval object. Executable plugins
come only from installed SDK code, never from imported content or an attached Vault.

## Migration

Version 16 is additive. Existing Vaults need no content rewrite, schema installation, or Dataset
migration. The `Captures/` directory is created by the first approved Capture transaction. Existing
ordinary notes are never scanned or converted automatically. A future Capture schema change must use
a versioned SDK migration and Engine Intent; validators reject unsupported schema versions.
