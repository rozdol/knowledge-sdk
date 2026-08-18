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

Schema version 1 remains the ordinary Capture contract. URL-backed bookmarks use additive schema
version 2 fields; they are still `type: capture` and `kind: bookmark`:

```yaml
---
id: "capture_<ULID>"
capture_id: "capture_<ULID>"
type: "capture"
schema_version: 2
kind: "bookmark"
title: "A synthetic street photography guide"
url: "https://photo.example/article?view=full"
canonical_url: "https://photo.example/article?view=full"
domain: "photo.example"
resource_type: "article"
user_note: "Хороший пример композиции."
collections:
  - "Photography references"
author_name: "Synthetic Author"
published_at: "2026-08-10T08:00:00Z"
description: "A bounded page description."
content_excerpt: "A bounded plain-text excerpt."
content_hash: "<SHA-256>"
fetch_status: "succeeded"
fetched_at: "2026-08-18T09:30:00Z"
page_language: "en"
reading_status: "unread"
topics:
  - "photography"
  - "street-photography"
evidence:
  - "evidence_<chat-ULID>"
  - "evidence_<page-ULID>"
# ordinary Capture identity, lifecycle, audit, tag, and sensitivity fields follow
---
Хороший пример композиции.
```

Optional fields are omitted when unavailable. The Capture `language` describes the user's annotation;
`page_language` may differ. `user_note` and the human-readable body preserve the user's wording and
are never replaced by a generated page summary. `resource_type` is metadata, not a new entity schema.
Supported values are `article`, `personal_website`, `portfolio`, `gallery`, `photo_gallery`, `blog`,
`documentation`, `project`, `reference`, `video_page`, `product_page`, `repository`, `forum_thread`,
and `unknown`.

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

Explicit save-link forms such as “Save this article…”, “Сохрани эту ссылку…”, and
“Αποθήκευσε αυτό το άρθρο…” select `knowledge.capture.bookmark`. A bare URL does not silently persist;
without clear conversational save context it clarifies. Hermes continues to call only `kg chat --json`.

```text
explicit save-link message -> normalize HTTP(S) URL -> duplicate check
  -> optional safe metadata Evidence -> CreateCapture(kind=bookmark) proposal
  -> exact approval -> existing Engine -> CaptureChanged
```

## URL normalization, enrichment, and duplicates

Normalization is deterministic: scheme and host are lowercase, default ports and fragments are
removed, empty paths become `/`, `utm_*` plus a small known tracking set are removed, and meaningful
query parameters remain in their supplied order. Credentials and non-HTTP(S) schemes are rejected.
The domain is derived from the canonical URL.

Existing active bookmark Captures are checked before fetch by normalized/canonical URL. Metadata may
then reveal a canonical URL, and a content hash may identify a moved resource. Exact matches return a
structured duplicate result; content-hash matches return a duplicate candidate. Both ask for review
instead of creating another proposal. Equal titles alone never merge bookmarks.

Set `KG_BOOKMARK_FETCH=off` or use `kg capture add-url URL --no-fetch` for explicit offline mode.
Otherwise the SDK attempts bounded HTML metadata retrieval. Every request and redirect is limited to
HTTP(S) public addresses and pinned to the address that passed the network check. Redirect count,
timeouts, response size, and content type are bounded. Failure records `fetch_status: failed` and
does not prevent proposal creation. A disabled fetch records `not_attempted`.

Successful retrieval may add title, canonical URL, description, author, publication date, page
language, OpenGraph type, resource type, topics, content hash, and a bounded textual excerpt. The
bounded rendition is stored by the existing immutable `SourceEvidenceStore`; only Evidence IDs and
bounded metadata appear in canonical Markdown. Large raw webpages are not archived into the Capture.

Web content is hostile data. Scripts are discarded, and every extracted string remains data. A page
cannot supply an agent instruction, SDK configuration, validator, executable code, plugin, approval,
policy, or authorization. Detected people, organizations, projects, authors, photographers,
galleries, and publications are read-only link candidates unless existing identity resolution safely
matches them; the page never creates those entities automatically.

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
kg capture add-url https://photo.example/article --note "Study this composition" --no-fetch
kg capture bookmarks
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

Capture search supports kind, status, time, title, topics, tags, and body. Bookmark matching also
uses user annotation, normalized/canonical URL, domain, resource type, collections, author,
description, and bounded excerpt. It recognizes questions
such as “What notes did I write last week?”, “What trading lessons have I recorded?”, “What questions
are still unanswered?”, and “What have I recently captured?”. `kg search` adds Capture matches to its
existing Dataset or graph response.

`kg analyze` loads policy-visible Captures into the same deterministic context as Graph, Dataset,
Activity, Intelligence, Planning, events, and cache state. Responses include `capture_evidence`, a
Capture signature, common themes, exact repeated wording groups, graph evidence from approved links,
and limitations. Restricted Capture text is never included. Association remains noncausal.
Bookmark analysis additionally reports deterministic domain, resource-type, and topic frequencies;
these outputs remain derived and noncanonical.

## Plugin API

Trusted installed code registers one named object with one or more of these methods:

```ruby
plugin = MyCapturePlugin.new
KnowledgeCapture.registry.register(plugin)

# Optional plugin methods:
# enrich_capture(attributes) -> Hash (may suggest bookmark resource_type metadata)
# extract_capture_topics(text) -> Array<String>
# capture_link_candidates(text, context) -> Array<Hash>
# build_capture_promotion(capture, kind, options) -> Array<KnowledgeGraph::Intent> or nil
# capture_recommendations(capture) -> Array<String>
```

Plugin inputs are immutable projections. Plugins get no Engine or approval object. Executable plugins
come only from installed SDK code, never from imported content or an attached Vault.

## Migration

Version 16 schema-v1 Captures remain valid and require no rewrite. Version 17 adds schema version 2
for newly approved URL-backed bookmarks only. Existing Markdown notes, browser history, old bookmark
files, graph entities, and Dataset rows are never scanned or converted. The `Captures/` directory is
still created only by the first approved Capture transaction. No background migration or network
fetch runs during `kg attach`, `kg doctor`, or `kg migrate`.
