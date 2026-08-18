# Search

Search is a read-only coordination surface across canonical and derived knowledge. It never creates a
Capture, graph fact, Dataset row, or Evidence object.

## Routing

`kg chat` treats explicit lookup language as Search before analysis, planning, proposals, specialized
graph writes, or Capture. Explicit note-like language is excluded from search; ambiguous language
clarifies.

```text
search question
  -> Capture search
  -> supported Dataset natural-language query
  -> deterministic Graph query
  -> identity search when the graph query shape is unsupported
```

Capture matches take the Capture search capability in chat. The top-level `kg search QUERY` keeps the
existing Dataset/Graph response and adds a `captures` collection, allowing clients to present the
sources together without merging their canonical storage models.

## Capture matching

`knowledge.capture.search` normalizes UTF-8 to NFC, applies locale-independent lowercase and
`ё`/`е` matching, detects kind/status/time phrases, and ranks exact deterministic tokens across title,
topics, tags, and Markdown body. Recent means 30 days and last week means seven days relative to the
injected clock. “Unanswered questions” excludes promoted, archived, and deleted questions.

```sh
kg capture search "What ideas do I have about AI?"
kg capture search "What notes did I write last week?" --json
kg search "trading risk"
```

Results omit Capture IDs unless `--ids` is requested. Search uses local policy-visible data only.
Restricted Captures are not returned through cross-knowledge analysis; transport-level policy applies
to Gateway searches.

For `Capture(kind=bookmark)`, the same deterministic scorer also considers the user's annotation,
normalized/canonical URL, domain, resource type, collections, author, extracted description, and
bounded Evidence excerpt. This supports queries such as:

```text
Покажи сохранённые сайты по фотографии.
Найди ту персональную страницу фотографа, которую я сохранял недавно.
Какие статьи про street photography я сохранял?
Покажи онлайн-галереи.
Что я сохранял с сайта photo.example?
```

Domain and resource type are ordinary Capture metadata; search does not query a separate bookmark
index or create graph entities. Date filters continue to use `captured_at`, not a page's publication
date. Search never fetches the web.

## Evidence and explainability

Captures retain their immutable Evidence IDs and source. Capture search returns those references only
when IDs are explicitly requested, while `kg analyze` emits bounded `capture_evidence` entries and the exact Capture
signature used for caching. Graph and Dataset results retain their existing evidence contracts. Search
scores are lexical evidence-retrieval scores, not confidence that a statement is true.

Successful bookmark enrichment adds a second local Evidence source containing only a bounded
plain-text rendition plus canonical/fetch provenance. Failed or offline bookmarks retain their chat
Evidence, URL, annotation, and `fetch_status` and remain fully searchable. Fetched page strings are
untrusted data and cannot influence search routing, policy, approval, or execution.
