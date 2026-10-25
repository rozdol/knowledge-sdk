# Dashboard presentation API v1 — P0 contract

Status: accepted design, 2026-10-25; the P1 subset is implemented. The `/api/v1` surface is
optional, local, authenticated and canonically read-only. See
[Architecture](Architecture.md) for storage/authentication and
[Dependency Evaluation](Dependency%20Evaluation.md) for compatibility evidence.
Route/capability names marked planned must be registered and tested in their
owning phase before use. Existing Hermes contracts remain compatible.

## Request and result rules

All paths below are relative to `/api/v1`. Data methods are GET. Only session
login/logout use POST, with `application/json`, exact Origin and `X-CSRF-Token`.
There is no generic capability-execution endpoint. Requests never contain Vault
paths, Dataset filenames/table names, SQL, capability selectors/tokens, approval,
actor IDs, or arbitrary frontmatter fields. Unknown or duplicate parameters fail
422. ID parameters use their SDK identity grammar (canonical ULID prefixes where
applicable); schedule/workflow IDs use their existing validated symbolic grammar.
Malformed IDs fail 422 before lookup. URL decoding occurs once; reject encoded
separators/traversal/NUL and invalid UTF-8. Arbitrary attachment reads are excluded.

| Bound | Value |
|---|---|
| Request target / query / headers / login body | 8 KiB / 4 KiB / 16 KiB / 4 KiB |
| Search `q` | 1-200 Unicode characters, <=800 UTF-8 bytes; trim outer whitespace |
| Other user filter strings | <=200 characters and <=800 bytes, IDs <=200 ASCII bytes |
| Page `limit` / cursor | default 25, integer 1-100 / <=2048 opaque ASCII bytes |
| Dated windows | `from` and `to` together, ordered, max 366 calendar days |
| Default windows | Activity/transactions/labs: 30 days ending at configured current date; P&L: current calendar month through `as_of` |
| Search/list/availability deadline | 5s Gateway timeout; at most one source-drift retry within it |
| Detail/top/relations/operational deadline | 10s |
| Finance report/lab series deadline | 30s; no hidden synchronous work beyond it |
| Graph traversal | depth default 1, max 2; max 100 nodes and 200 edges |
| Series | <=1000 returned points per compatible series, <=10 series per response |
| Finance full replay | Existing <=100,000-row service ceiling; never truncate replay input for display |
| Response / evidence / excerpt / detail text | <=1 MiB JSON / 20 references / 500 / 10,000 characters |
| Rate/concurrency | 120 data requests per session/minute, 240 globally/minute, max 4 active data requests |

`as_of` is an ISO date for contact ranking and date-scoped graph views; Finance
accepts a date or offset-bearing RFC3339 instant. Defaults derive once per request
from configured timezone, except Finance UTC accounting dates as described below.
Omitted graph/Finance lifetime history before `as_of` is not limited to a 366-day
replay; the date-window bound limits returned period/query windows only. Do not
default owner/subject when ambiguous. The browser must explicitly select one from
policy-visible scopes. Timestamps use RFC3339 with offset, UTC for computation.
Empty lists are only successful results with no visible matching records.

Every terminal data result uses this envelope (all keys required; nullable fields
are explicit). `data` is a typed object or null; no raw `AgentResponse` escapes.

```json
{
  "contract_version": "1.0.0",
  "request_id": "request_00000000000000000000000001",
  "status": "ok",
  "data": {
    "items": [{"id":"person_00000000000000000000000002","name":"Synthetic Contact","type":"person"}],
    "page": {"returned":1,"next_cursor":null}
  },
  "warnings": [],
  "scope": {"owner_id":null,"subject_id":null,"account_id":null},
  "window": {"from":null,"to":null,"bounds":null,"as_of":"2026-10-25","timezone":"Etc/UTC"},
  "computed_at": "2026-10-25T12:00:00.000000Z",
  "sources": [{"kind":"graph","version":"sv_opaque-example","observed_at":null}],
  "completeness": {"complete":true,"limitations":[]},
  "evidence": [],
  "error": null
}
```

`scope` contains only permitted selected IDs. `window.bounds` is `inclusive_dates`,
`inclusive_instants`, `half_open_instants` or null. Sources identify graph, Captures,
Datasets, audit or runtime with opaque visible-dependency versions, not paths or
raw database/snapshot signatures. `observed_at` is the authoritative source update
time or null. `computed_at` is never substituted for missing source freshness.
Evidence is `{record_id, evidence_id, role, label}` with optional absent keys; at
least one permitted ID is required, with a bounded plain-text label. No local file
URI, source filename/path, raw source span, attachment bytes or unsafe URL. No
preview endpoint exists; an unavailable preview is labeled as such.

| `status` | Meaning |
|---|---|
| `ok` | Supported, complete response within its declared recorded-data coverage |
| `empty` | Supported, successful query; zero visible matches |
| `partial` | Some valid results exist, but documented inputs/coverage are missing; exact affected totals are null |
| `unavailable` | Feature/permission/schema/storage/required scope cannot support this result; `data:null` |
| `stale` | Permitted result exists but an authoritative source/valuation freshness rule is exceeded |
| `error` | Request or computation failed; `data:null` and safe `error` |

Loading is client-only. Precedence for combined conditions: error, unavailable,
partial, stale, empty, ok. A partial result can also contain a `stale_source`
warning. `warnings` and `completeness.limitations` use objects `{code,message}` with
safe bounded messages; no private exception details. For example, an old Dataset
returns HTTP 200 with this relevant envelope fragment (other keys as above):

```json
{
  "status":"unavailable",
  "data":null,
  "warnings":[{"code":"dataset_upgrade_required","message":"Upgrade Dataset storage through the existing administrative workflow, then retry."}],
  "completeness":{"complete":false,"limitations":[{"code":"dataset_upgrade_required","message":"Browsing cannot migrate storage."}]},
  "error":null
}
```

Availability is a feature-level result, not proof of hidden object existence. Do
not return storage/version-specific reasons to a caller without that domain's
base permission. Lists have `items` and `page:{returned,next_cursor}`; no total,
hidden count, or estimated global count. Fixed reports do not paginate accounting
inputs. Bounds reached before a complete graph/series computation produce partial
data and `result_bound_reached`, never a fabricated complete answer. If a report
cannot calculate safely within its input bound, return unavailable and null totals.

## HTTP failures, jobs and pagination

| HTTP | Safe code / behavior |
|---|---|
| 200 | Terminal envelope, including supported empty/unavailable/stale/partial states |
| 202 | Accepted owned read job ticket, not a completed widget envelope |
| 400 | `invalid_request`: malformed JSON, query encoding or framing |
| 401 | `authentication_required`: absent/expired/revoked session or bad login; clear private client state |
| 403 | `request_forbidden`: Host/Origin/CSRF failure or forbidden non-object operation |
| 404 | `not_found`: unknown route, absent/hidden object, another session's job, expired job |
| 405 | `method_not_allowed`, fixed Allow header; no alternate write method |
| 409 | `context_changed`: expired/source-changed cursor or repeated capability drift; restart query |
| 413 / 414 / 431 | `request_too_large`: body / target / headers |
| 415 / 422 | `unsupported_media_type` / `invalid_arguments` |
| 429 | `rate_limited`, Retry-After seconds, no queuing unbounded work |
| 500 / 503 / 504 | `internal_error` / `service_unavailable` / `timeout`; no stack trace or raw exception |

Other than a bare rejection by the HTTP parser, failures use the terminal envelope
with `status:error`, `error:{code,message}`, no data, and incomplete coverage.
Gateway PolicyDenied for an object and CapabilityNotFound map to the same 404 with
identical body shape. Missing permissions for a whole widget yield unavailable
`not_available`. Do not distinguish hidden/absent object IDs through messages,
counts, job polling, cursor contents, or source versions. Do not expose Gateway
telemetry/trace inspection through the browser.

All v1 routes may initially execute synchronously. If a registered asynchronous
read is introduced, it must retain this ticket contract:

```json
{"contract_version":"1.0.0","request_id":"request_00000000000000000000000003","job":{"id":"job_00000000000000000000000004","state":"queued","poll_after_ms":1000}}
```

HTTP 202 includes `Location: /api/v1/jobs/<id>`. GET `/jobs/:id` returns a normal
envelope with `data:{job_id,state,progress,result}`; result is null until completion,
then a complete widget envelope. States are queued/running/succeeded/failed.
Only the creating browser session/authorization epoch can poll. Consult Gateway
`job_status` with that session's unique agent identity; an opaque job ID is not
authority. Limit 20 retained jobs/session, 100/process, 10-minute terminal TTL and
30s execution deadline. Current JobManager is in-memory and unbounded; P1 must add
dashboard-specific bounded admission/expiry without changing default SDK callers.
On logout remove access and discard retained results; already-running read work
can finish under its deadline but cannot publish a result to another session.
Restart loses jobs; the user reruns the read. No cancellation endpoint or durability
promise. Durable automation jobs are a separate route and schema.

Cursors are random 32-byte handles into process memory (max 100/session, 1,000
global, five-minute TTL), not exposed base64 offsets or serialized record payloads.
Bind each to session, authorization epoch, capability ID/version, permitted source
versions, selected scope, normalized filters, stable sort and last key. Validate
all bindings on every page. Unknown/cross-session cursors fail 409 identically;
malformed syntax fails 422. Hidden-only changes cannot alter permitted source
versions. Source/authorization changes discard cursors; do not append a new
snapshot to an old list. Keep cursor metadata/last keys only, not cached graph facts.

Stable ordering: P1 entity search uses existing exact identity signals, filtered
before redirect collapse and limiting, then immutable ID order;
contact lists use normalized name then ID; top uses score descending then ID;
relations breadth-first depth then endpoint ID then edge ID; Captures relevance
descending then captured_at descending then ID (recent: captured_at descending/ID);
Activity created_at descending/ID; transactions effective_at/sequence/event_id
descending; lab rows test_date descending/row_id; series test_date ascending/row_id;
scopes and schedules ID ascending; jobs/notifications timestamp descending/ID.
All ties use the full immutable ID, not filesystem order or locale collation.

## Permissions and capability registration

Every planned manifest is version `1.0.0`, `effects:read_only`, `approval:none`,
`risk:low`, idempotent, REST-enabled, with strict typed input/output schemas and
Gateway validation/leak guards. Add through the existing SDK registrar, never
attached code. Capability arguments use the table's parameter names, except route
`:id` maps to `entity_id`, `capture_id` or `job_id` as appropriate. `q` maps to
`query`. HTTP `cursor` is resolved server-side to a validated `after` sort key;
it is not passed as SQL. Domain handlers validate the key and perform visible-first
keyset pagination. No frontend filter becomes a natural-language prompt.

Existing base grants: `graph:read`, `intelligence:read`, `capture:read`,
`dataset:read`, `finance:read`. Existing exceptional grants: `graph:private` for
email/phone; `graph:restricted`, `capture:restricted`, `dataset:restricted`,
`finance:restricted`. Finance restricted inclusion requires **all three** graph,
Dataset and Finance restricted grants, plus visibility of every referenced identity.
Clinical restricted rows/subjects require both graph and Dataset restricted grants.
Capture linked identities require their graph permission even with Capture access.

New permission semantics, to register/document with their manifests in the owning
phase: `activity:read` permits safe existing change-history projections (P3);
`health:read` permits typed laboratory rows for visible subjects in addition to
`dataset:read` and `graph:read` (P5); `orchestration:read` permits sanitized configured
KG schedule/job metadata (P6); `notification:read` permits safe informational
notification metadata (P6). These names are reserved design contracts, not currently
implemented authority. No run/cancel/enable/ack/write power is implied.

Optional grants come from the operator settings at startup. The explicit capability
allow-list is exactly the registered data handlers below for enabled features and
existing search/get as needed; it excludes broad analysis, planning, conversational
Finance, all proposals and notify/write handlers. Availability rechecks each
feature's permissions before schema/storage introspection; Home composes only
those permitted handlers. Do not grant broad permissions just to discover absence.

## Route mapping and typed data

### Session, discovery, Home and search (P1; overview composition P6)

| Method/path | Parameters | Gateway mapping / result |
|---|---|---|
| GET `/session` | None | Local auth infrastructure; pre-login `{authenticated:false,csrf_token}` only; authenticated `{authenticated:true,csrf_token,expires_at,display_label,timezone,tzdata_version}`; never paths/secrets/capability tokens/permission dumps |
| POST `/session/login` | JSON `secret` only | Local auth; rotated session response as above; no Gateway write |
| POST `/session/logout` | Empty JSON object | Local auth; revoke; HTTP 200 `{authenticated:false}` |
| GET `/dashboard/availability` | None | P1 companion-registered `kg.dashboard.availability` 1.0.0 (`graph:read`); per-feature `{feature,state,reason}` using discovery + permitted metadata checks |
| GET `/dashboard/overview` | Optional `as_of` | Host composition of mapped handlers; `{widgets:{key:envelope}}`, independent widget errors; no new authority |
| GET `/search` | Required `q`; optional `entity_type`, `limit` | Existing `kg.entities.search` 1.0.0, `graph:read`; query/entity_type/limit, no cursor; bounded graph identity matches |

Search returns only ID/type/name/aliases/record_status and permitted match reasons; no
arbitrary attributes. P1 must filter restricted entities before limiting results.
No search-as-analysis, Dataset provisioning, or raw Markdown fallback. Later Contacts,
Capture and topic/resource search retain independent result states in the UI;
do not present their combined counts as unique cross-source entities. Availability
states: `available`, `empty`, `not_available`, `unsupported`, `upgrade_required`.
`empty` requires a supported visible source; denied features always `not_available`.
The six categories and Home always have UI entries. Calendar/diagnoses/learning
progress/Hermes/OS are explicit unsupported features, not fake empty timelines.

### Contacts, Captures and Activity (P3)

| GET path | Filters | Planned capability / required permissions |
|---|---|---|
| `/contacts` | `q` optional, limit, cursor | `kg.contacts.list` / `graph:read` |
| `/contacts/top` | `as_of` | `kg.contacts.top` / `graph:read`, `intelligence:read` |
| `/contacts/:id` | None | `kg.contacts.get` / `graph:read` |
| `/contacts/:id/relations` | `depth`, `as_of` | `kg.contacts.relations` / `graph:read` |
| `/captures` | `q`, `kind`, `status`, `from`, `to`, limit, cursor; q optional | `kg.captures.list` / `capture:read` |
| `/captures/:id` | None | `kg.captures.get` / `capture:read` |
| `/activity` | `q`, `from`, `to`, limit, cursor | `kg.activity.list` / `activity:read`; add graph/Capture/Dataset domain checks per included item |

Contact handlers reuse GraphReader, GraphSnapshot and existing Intelligence feature
calculations over a **visible** snapshot, not new importance metadata. Public
contact fields: id/type/name/aliases/status; emails/phones only with graph:private.
Relations contain permitted node IDs/labels and edge IDs/predicates/direction;
no hidden endpoints, edges or path-derived scores. Partial bounds are explicit.

Freeze top ranking `interaction-v1`: score = 0.6 * `recency_score` + 0.4 *
`interaction_frequency`, using existing feature versions 1.0.0, half-life 90 days
and 365-day frequency window, over visible recorded interactions at `as_of`.
Use existing self identity where explicitly supplied by metadata; do not invent
one. Return up to 10 people, score, formula version, component values, visible
interaction count/latest date and evidence reasons. If there are no interaction
signals, components/score are null and state unavailable; do not claim zero
importance. If fewer than 10 people have signals, return fewer with a limitation.
No health, Finance, private contact fields, or hidden graph degree enters ranking.
Unknown-signal contacts remain accessible in normal lists, ordered by name/ID.

Capture handlers reuse Store and Search token scoring, with typed filters that do
not infer kind/time/status from literal `q` wording. Add a typed read entry point
in that subsystem; preserve conversational `kg.captures.search` 1.0.0 compatibility.
List fields: id/kind/title/status/captured_at, bounded literal-text excerpt,
permitted tags/topics/links. Detail adds a bounded plain-text rendition, safe
bookmark metadata and evidence IDs; no raw Markdown serialization or file paths.
Long text signals `text_truncated`; do not invent full-content availability. Omit
hidden links/labels before relevance computation. Creation time is not occurrence
time. Activity uses the existing projection with read-only Dataset injection and
no disk cache, with only id/type/summary/created_at/source/visible objects and safe
evidence; no undo/restore action, approval details or hidden placeholder counts.
Activity includes permitted supported sources independently, with missing-source
warnings and half-open instant windows. Do not turn it into a personal-events model.

### Finance (P4)

| GET path | Filters | Planned capability |
|---|---|---|
| `/finance/scopes` | None | `kg.finance.scopes` |
| `/finance/net-worth` | Required `owner_id`; optional `as_of`, `currency` | `kg.finance.net_worth` |
| `/finance/positions` | Required `owner_id`; optional `account_id`, `asset_id`, `as_of`, limit, cursor | `kg.finance.positions` |
| `/finance/liabilities` | Required `owner_id`; optional `as_of`, `direction` | `kg.finance.liabilities` |
| `/finance/transactions` | Required `owner_id`; optional `account_id`, `asset_id`, `from`, `to`, limit, cursor | `kg.finance.transactions` |
| `/finance/pnl` | Required `owner_id`; optional `account_id`, `asset_id`, `from`, `to`, `as_of`, `period` | `kg.finance.pnl` |

All require existing `finance:read`, `dataset:read`, `graph:read`. Currency is an
existing supported three-letter currency, default EUR for net worth; P&L is native
currency only, with no combined currency parameter. `direction` is receivable or
payable, omitted for both. `period` is total (default) or monthly. Owner/account/
asset IDs must refer to visible, related identities; hidden/absent explicit scopes
return identical 404. Absent required owner returns 422, not inferred consolidation.
Scopes returns visible owners/accounts/assets and their allowed links/currencies,
never account numbers, IBANs, arbitrary identifiers_json or details_json.

Reuse `KnowledgeFinance::Service#networth`, `#holdings`, `#debt_report`, `#pnl`,
`#monthly`, and existing row/projection logic; add typed read handlers rather than
invoke `kg.finance.read`'s conversational parser. Service must receive the read
facade and visible catalog. Filter account-specific positions after **complete**
owner replay; validate that account belongs to owner. Transaction display pagination
does not limit the calculation history. Finance storage unavailable must propagate
as unavailable before Service's missing-Dataset rescue could imply empty balances.

Report data follows existing Finance report semantics/schema, wrapped in the v1
envelope with safe field/evidence projection. Preserve exact decimal strings,
currency/unit/multiplier, source mark/FX timestamps, recorded-history coverage,
missing basis/marks, known subtotal and null unavailable totals. For example:

```json
{"owner_id":"financialowner_00000000000000000000000005","currency":"EUR","net_worth":null,"known_subtotal":"1250.00","coverage":"policy_visible_recorded_history","execution_authorized":false}
```

This fragment illustrates precision/missingness, not a replacement for the existing
Finance report schema. Fiat/native currencies never sum without supported FX;
fees/transfers retain existing accounting meaning. Range dates are inclusive UTC
start/end (`00:00:00` through `23:59:59.999999`), matching Service#timestamp. Instant
endpoints are inclusive as well. Do not reinterpret those dates in browser-local
time. Preserve source price freshness rules (24h for ordinary reports). Physical
settlement, broad corporate actions, tax/business/household P&L and live prices/news
remain unavailable as documented by the Finance subsystem.

### Laboratory history (P5)

| GET path | Filters | Planned capability / permissions |
|---|---|---|
| `/health/labs` | `subject_id`, `panel`, `analyte`, `from`, `to`, limit, cursor; optional `scopes=true` | `kg.health.labs` / `health:read`, `dataset:read`, `graph:read` |
| `/health/labs/series` | Required `subject_id`, `analyte`; optional panel/from/to/unit/specimen/laboratory/method | `kg.health.lab_series` / same grants |

`scopes=true` accepts no other filters and returns only permitted known subject
IDs/labels, enabling explicit selection. Ordinary reads require subject_id. Subjects
come from explicit Dataset ownership or supported explicit row subject metadata;
an unowned ambiguous table returns unavailable `subject_scope_unknown`, not an
inferred person. Existing blood-test schema need not gain a physical subject column.
Use trusted template metadata to recognize compatible definitions and map legacy
aliases only where explicitly supported. Unknown custom schemas remain unsupported.

Rows retain row/Dataset IDs, test_date (or supported observed_at), panel, analyte,
value, unit, original reference_low/high/text, flag, specimen, laboratory, method
when recorded, and permitted Evidence refs. Reserved source URIs/filenames/spans
stay private. Nonnumeric values stay table text; no numeric coercion or invented
intervals. Series groups by subject/analyte/unit/method/specimen/laboratory with
null method/specimen labeled unknown, never assumed compatible with known values.
No unit conversions except trusted existing supported ones. Bounds on numeric
series require explicit aggregation metadata or partial/raw bounded results; never
silently downsample a clinical signal. Date filters are inclusive date-only and
max 366 days. Diagnosis and treatment recommendations are unavailable.

### Operational inventory (P6)

| GET path | Filters | Planned capability / permissions |
|---|---|---|
| `/automation/schedules` | limit, cursor | `kg.orchestration.schedules` / `orchestration:read` |
| `/automation/jobs` | `status`, limit, cursor | `kg.orchestration.jobs` / `orchestration:read` |
| `/notifications` | `kind`, limit, cursor | `kg.notifications.list` / `notification:read` |
| `/jobs/:id` | None | Existing Gateway#job_status using owning session agent; transport infrastructure |

Read only explicitly selected trusted SDK schedule configuration and preexisting
runtime stores. Schedules: id/description/cron/enabled/source=`kg`/execution timezone,
last recorded run and next_due where supported, worker_health=null otherwise.
Jobs: id/workflow/status/progress/created_at/updated_at, plus started_at/completed_at
only when execution history supplies them, generic sanitized outcome,
source=`kg`; no arguments, arbitrary outputs, exception details or replay controls.
`status` accepts queued/running/succeeded/failed/cancelled, the durable manager's
current transitions. Retry details are metadata, not an invented `retrying` state;
do not conflate status enums across job families.
No configuration discovery from Vault text and no scheduler execution on read.

Existing notifications lack reliable entity-level privacy provenance. Default
projection exposes permitted ID/kind/timestamp, generic SDK-generated label and
`executable:false`; it omits free-form title/message/source text. Only expose richer
text in a future compatible handler after proving all referenced records/evidence
are permitted; unknown provenance is not authorization. Durable job summaries use
the same rule. Hidden/protected items are omitted before pagination. Missing store
is unavailable, existing empty store is empty, no store is created to change that.
Hermes and OS jobs are `not_connected`. No fake worker heartbeat, calendar events
or automatic notification acknowledgement.

## Contract evolution and handoff gates

P1 exports `optional/dashboard/config/api-response.schema.json` for the common
terminal widget envelope, `settings.schema.json` for operator configuration and
`dashboard.json` for its registered availability capability. Session control
responses are the separate small objects documented above. P1 search remains the
existing bounded exact-identity capability (no cursor), now with visible-first
immutable-ID ordering and private contact/external identity signals requiring
`graph:private`. A reached limit returns partial. Later asynchronous routes must
add a typed result adapter before admitting 202; the current owned-job route returns
metadata with result:null and P1 only admits synchronous read contracts.

P1 ships only auth, availability, search and owned-job infrastructure. Other routes
are absent (404) until their owning phase; discovery can label features unsupported.
P2 may display unavailable states for absent routes. P3-P6 add their manifests,
permission semantics, typed SDK methods, strict output schemas and fixtures together.
Changes to these accepted design names/semantics require a Progress decision with
updated consumers/tests; a breaking implemented contract requires a version change.

P7 verifies every route mapping, object denial, limit, cursor/session isolation,
hostile content, Dataset nonmutation, privacy-safe aggregates and declared failure
state against synthetic sources. No first-release feature is considered complete
just because its capability ID appears in discovery.
