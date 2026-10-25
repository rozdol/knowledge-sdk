# Dashboard architecture — P0 contract

Status: accepted design, 2026-10-25. Inspected revision: `324aed9`.
No dashboard host, route, permission registration, or browser application is
implemented by P0. All new names below are implementation requirements for P1-P7.
See [API Contract](API%20Contract.md), [Dependency Evaluation](Dependency%20Evaluation.md),
[Implementation Plan](Implementation%20Plan.md), and [Progress](Progress.md).

## Boundary and lifecycle

The optional dashboard is a client of the existing Agent Platform. Canonical
Markdown, Capture bodies, Dataset rows, schemas, approval receipts, and Engine
behavior retain their existing owners. There is no dashboard fact store.

```text
same-origin browser -> KnowledgeSDK::Dashboard Rack app
  -> fixed route/typed argument mapping
  -> policy-filtered Gateway discovery -> opaque token -> Gateway execution
  -> existing SDK readers / new registered domain read handlers
  -> Markdown / existing read-only Dataset connection / existing runtime records
```

The host never calls the CLI, executes shell commands, opens SQLite itself, invokes
private handlers, or accepts capability IDs/tokens, SQL, storage paths, or executable
configuration from requests. Hermes keeps its independent adapter and contracts.
Proposal creation, approval, submission, plugin installation, imports, fetches,
schedule execution, notification acknowledgement and external models are excluded.

Freeze the future launch syntax:

```sh
kg dashboard serve --vault PATH --timezone IANA --secret-file FILE
kg dashboard serve --vault PATH --timezone IANA --secret-file FILE --port 8765 --settings FILE
```

Existing global `--config` and `--dataset-db` options also apply (including their
existing environment equivalents). `--vault` is mandatory for this command; do not
fall back to the active registry or current directory. Port defaults to 8765 and
must be 1024-65535. Bind only `127.0.0.1`; no `--host`, LAN, proxy, or multi-Vault
mode in this release. Stop with SIGINT/SIGTERM, close readers, revoke sessions and
discard jobs. Do not stop or start the independent scheduler/worker.

Resolve the Vault and Dataset override once at startup through the existing
locator/configuration semantics, and freeze absolute paths in an immutable server
context. Dataset precedence remains explicit override / `KG_DATASET_DB` / external
configuration `dataset_db` / Vault-relative `.knowledge/datasets.sqlite3`. A relative
override is relative to the selected Vault. Pass the resolved path explicitly into
every new reader; never change process globals during requests. Do not attach,
detach, install a profile, write a registry, or initialize a Vault at startup.

## Optional packaging and runtime

Choose an optional companion gem `knowledge-sdk-dashboard`, version-aligned with
and depending on the exact `knowledge-sdk` version. Implement it under
`optional/dashboard/` with its own gemspec, `lib/knowledge_sdk/dashboard.rb`, and
packaged `assets/`. The current core gem's globs exclude that directory. Core CLI
dispatch lazy-requires the component only for `dashboard`; if absent, report an
installation instruction and fail without changing a Vault. Core requires and
ordinary commands must work without any web gems. Read-safe Dataset primitives
belong in the core owning subsystem, not in the optional component.

Use Rack 3.2.7, rackup 2.3.1's WEBrick adapter, and WEBrick 1.9.2. Use TZInfo 2.0.6,
concurrent-ruby 1.3.8 and tzinfo-data 1.2026.5 (IANA 2026e). Pin these initial optional
dependencies exactly. Do not add them to the core gemspec. Use one process, no
forking, at most four active data requests; additional work receives 429. Set
WEBrick request/read timeout to 10 seconds and header/request-line limits before
dispatch; data computation has its separate Gateway deadline. No Rack sessions,
Rack static middleware, upload parsing, or multipart parser is needed.

Puma 6.6.1 / nio4r 2.7.5 satisfy declared Ruby requirements but their native build
failed on the available system Ruby due to missing `ruby/config.h`. Puma 8.0.2
requires Ruby >=3.0. WEBrick avoids a native toolchain requirement and is adequate
for the bounded local host. This is an explicit resolution, not authorization to
raise the SDK Ruby minimum. See the evaluation evidence and future matrix gates.

Use HTML/CSS and native ES modules, no frontend framework or production Node
dependency. Package static bytes in the optional gem with a generated allow-list
and SHA-256 asset names. No CDN, remote fonts, remote images, source-content HTML,
service worker, or Markdown renderer. Use small native SVG charts with table
alternatives and `textContent` labels; no chart-library dependency. Financial chart
coordinates can approximate decimal values; authoritative labels remain strings.
Use development-only `@playwright/test` 1.56.1 with its pinned browser revisions,
Node 22.13.1, Chromium and Firefox, at 1440x900 and 390x844. P2 introduces its lockfile
and browser tests; P0 makes no visual or browser compatibility claim.

## Authentication and request security

The operator provisions a random base64url secret with at least 32 random bytes in
an owner-only regular file outside the Vault. `--secret-file` is required; refuse
symlinks, group/other-readable files, empty or malformed secrets, and files inside
the Vault. Load only at startup and retain a SHA-256 digest for constant-time
comparison. Never print or generate the secret in a URL. Restart to rotate it.

An unauthenticated `GET /api/v1/session` creates a bounded, five-minute pre-login
session and returns its CSRF token, with no Vault context. The cookie contains
only a cryptographically random 32-byte identifier. Login requires that cookie,
the matching `X-CSRF-Token`, exact Origin, and JSON `{secret}`. Rotate the session
ID and CSRF token on success. POST logout revokes it. Both operations also check
Host, content type, body size and fetch metadata; this includes login CSRF.

Use cookie `kg_dashboard_session`, HttpOnly, SameSite=Strict, Path=/, no Domain,
and Max-Age consistent with server expiry. Secure is mandatory if TLS is introduced;
the local HTTP release must not claim a Secure cookie. Sessions expire after 30
minutes idle or eight hours absolute, whichever comes first. Polling does not
extend idle time; only login or explicit foreground user requests do. Maximum 20
authenticated plus 20 pre-login sessions; reject excess with 429. Memory only,
cleared on restart. Login: five attempts per client per minute, twenty globally,
using bounded counters and monotonic time. Return the same 401 for bad credentials.

Each authenticated browser session gets its own `AgentIdentity` ID, e.g.
`dashboard:<random>`, so Gateway job ownership does not cross browser sessions.
Never use `local_cli_identity`, wildcard permissions, or `telemetry:read_all`.
Create the Gateway with `environment: "read_only"`, explicit nonempty
`allowed_capabilities`, and explicit permissions listed in the API contract.
Fail closed if the allow-list is empty. Discovery and every invocation recheck
policy; reject a contract with non-read effects or approval other than `none` even
if accidentally discovered. Tokens remain server-side. On stale-token failure,
rediscover and retry a read once; repeated drift returns 409.

Default permissions: `graph:read`, `capture:read`, `intelligence:read`. Optional
domain grants are explicit operator settings; restricted/private grants are never
enabled by default. Settings are version-1 JSON, outside the Vault, operator-owned,
read once; allow only documented permission names, display label and an explicit
SDK-owned schedule configuration path/execution timezone. Unknown keys fail startup.
Do not load configuration or code discovered in notes. Policy changes require a
restart, invalidate sessions/tokens/cursors/jobs, and generate a new authorization
epoch. Each request still enforces the current identity and Gateway policy.

Allowed Host is exactly `127.0.0.1:<configured-port>`; reject other Hosts, duplicate
Hosts, forwarded-host headers and absolute-form foreign authorities before cookies
or static dispatch. Print the matching canonical URL at startup. State-changing
session requests require `Origin: http://127.0.0.1:<port>` and CSRF token; data GETs
reject foreign Origin and `Sec-Fetch-Site: cross-site`, allowing absent Origin for
same-origin navigation/clients. No CORS headers. Request filters reject malformed
encoding, duplicate/unknown parameters, traversal, NUL and over-limit input. Static
routes serve only the compiled allow-list; never join request paths to Vault paths.

All responses use `Cache-Control: no-store`, `Referrer-Policy: no-referrer`,
`X-Content-Type-Options: nosniff`, and a CSP of `default-src 'none'; script-src 'self';
style-src 'self'; img-src 'self'; connect-src 'self'; font-src 'self';
base-uri 'none'; frame-ancestors 'none'; form-action 'self'`. No inline scripts or
styles. Imported text is always literal text. External bookmark links, when
explicitly clicked, allow only validated HTTP(S) and use `noopener noreferrer`;
the dashboard performs no fetch or preview. Sensitive filters stay in JS memory;
API GET query strings must never be copied into navigation/history/referrers.
No localStorage, IndexedDB or persistent client payload cache. Clear in-memory
payloads on logout/expiry. Logs contain route templates, random request IDs, status
and duration only, never query strings, identifiers, headers, secrets or payloads.
Inject a dashboard telemetry recorder capped at 1,000 sanitized events with a
10-minute TTL; evict oldest entries, never persist them. A restart loses telemetry.

## Nonmigrating Dataset facade (P1-a)

Introduce `StructuredDataset::Reader` with `vault_root:`, explicit `database_path:`
and `clock:`. It is a read facade, not a writable Engine subclass. It exposes
`availability`, `list`, `describe`, `query`, `stats`, `schema_history`,
`activity_records`, and a scoped consistent-read block. Reuse Registry, Definition,
coercion, Names and Query in the owning subsystem; extract shared read helpers
where needed without changing existing Engine defaults or writer behavior.
There is no create/insert/update/replace/delete/import/migrate method and no graph
Engine, event bridge, proposal store, receipt store or writer lock construction.
Keep `query` compatible with existing Engine read consumers (`reference`, `where`,
`order`, `limit`, `offset`, `columns`, `row_id`), with existing validation/binding;
this internal compatibility method is not a public SQL/where transport. Availability
returns structured status/code plus internal engine-version diagnostics; only
permission-checked safe codes reach the browser. A consistent-read block pins one
connection/transaction across a report's multiple `query` calls, not a new connection
per page. Close it in ensure on success, timeout or error.

Add a separate `Database#with_read_connection` that opens with SQLite
`READONLY` flags, never `CREATE`. No mkdir, `migrate!`, WAL-mode assignment,
checkpoint, vacuum, schema repair, or write transaction. Set `query_only=ON`,
use a 100ms busy timeout and an ordinary read transaction. A pre-check avoids
probing absent paths; READONLY open remains authoritative if files change after it.
The operator-selected DB may be outside the Vault; browser requests cannot select
or replace it. Do not use SQLite `immutable=1`: existing WAL must remain visible.
Do not copy only the main DB file or ignore WAL to manufacture a stable snapshot.

| Storage state | Reader/API result | Side effects |
|---|---|---|
| No file or parent directory | `unavailable`, `dataset_storage_missing` | No file/directory creation |
| `user_version` 0, 1 or 2 | `unavailable`, `dataset_upgrade_required` | No migration, rows or schema changes |
| Current version 3, valid required catalog/tables | Ready | Read transaction only |
| Version >3 | `unavailable`, `dataset_engine_too_old` | No downgrade |
| Corrupt/incompatible catalog or invalid definition | `unavailable`, `dataset_storage_invalid` | No repair |
| Locked/unreadable DB or inaccessible WAL | `unavailable`, `dataset_storage_unreadable` | No fallback writable connection |
| Missing required domain columns/template semantics | `unavailable`, `dataset_schema_unsupported` | No schema provisioning |

Engine `user_version` and each Dataset's independent schema version are distinct.
Accept supported older per-Dataset definitions only when the trusted domain reader
explicitly maps them; never reinterpret arbitrary custom rows as clinical/Finance
data. Detect incompatibility without reading hidden catalog details into responses.
Error messages expose safe codes and operator recovery instructions, never paths,
SQL, raw SQLite errors, or hidden Dataset presence. Recovery is an explicit existing
administrative migration/approved lifecycle operation outside the dashboard.

SQLite may maintain existing WAL shared-memory coordination files while opening
an existing writable directory. This is the only permitted Vault-local read side
effect, and must not create the main database or `.knowledge` parent. If a platform
cannot open the existing WAL safely, report unreadable. P1 tests compare canonical
note bytes and logical SQLite catalog/schema/rows/user_version, including WAL-visible
commits, rather than isolated main-file hashes. Test before/after directory listings
for absent storage and allow-list WAL/SHM effects only for existing storage.

Inject this reader into dashboard Gateway Services via an additive constructor
factory option in `AgentPlatform.build`; existing callers retain their defaults.
In the dashboard service graph, fail fast on accidental writer/proposal access.
Use the facade for all Dataset consumers, including Finance, Activity and discovery.
`KnowledgeFinance::Service` must receive it explicitly: its default constructor
creates a writable Dataset Engine. Do not call the conversational Finance handler
for typed widgets; it also constructs ProposalStore and conversation state.

Activity currently calls `ActivityAdapter#audits`, which migrates existing storage,
and `Timeline#all`, which writes a derived Vault cache. P1-a prepares an injected
read-only Dataset adapter and nonpersisting cache option for later P3 use; preserve
CLI defaults. Exclude restricted/redacted placeholder activities entirely before
pagination; their existence/counts are not dashboard content. A missing Dataset
source yields partial graph/Capture Activity with a warning, not silent complete
history. Runtime inventories read existing stores without constructing an
Orchestrator, Scheduler runner, notification writer or job-resume loop.

## Discovery, privacy and schema differences

Availability is the intersection of policy-filtered discovered contracts, supported
SDK reader semantics, and parsed schema/metadata readiness. It is not a test of
folder names or the mere presence of a manifest. The current profile detector
recognizes personal-crm by two directories; that is insufficient for feature readiness.
Use SchemaRegistry keys/fields and trusted template registry IDs/versions/digests,
then visible canonical Dataset metadata and the read facade. Do not install absent
schemas, execute schema Markdown, or assume that registered templates imply data.
Capture has an SDK-owned format and needs no CRM profile. Generic Vaults retain
search/Capture support when schema-compatible; unsupported contact/Finance/Health
features return specific safe unsupported states. A denied feature is simply
`not_available` without disclosing whether hidden records or plugins exist.

New handlers must enforce graph entity/edge, Dataset, row, subject/owner/account,
linked identity, and Evidence sensitivity before scoring, pagination, traversal or
accounting. Public field allow-lists supplement the existing SecurityGuard (its
forbidden-key filter alone is not an authorization policy). Do not serialize arbitrary
frontmatter, private identifiers, nested JSON or raw Markdown. Private contact
points require `graph:private`; restricted data uses the existing domain grants
described in the API contract. No new permission grants weaken Engine gates.

The current entity handler truncates before visibility filtering. P1 must fix the
existing search handler to filter first, retaining its input/output contract, with
a regression where hidden matches precede visible ones. P3 graph traversal and
contact ranking must operate on a policy-visible snapshot; filtering a path or
score computed from hidden records is insufficient. The existing path/intelligence
handlers alone do not establish that property.

## Time, source versions and refresh

Require an explicit valid IANA display timezone at launch. Use TZInfo with the
packaged Ruby data source, never process-global `ENV['TZ']`. Return timezone and
tzdata version in session context. Preserve date-only clinical values as dates.
Activity instant windows are half-open `[from,to)` with offset-bearing RFC3339;
derive local day boundaries by converting successive calendar midnights, never
adding 86,400 seconds. Ambiguous local wall times require an offset; nonexistent
times fail 422. DST fixtures include 23/25-hour days in Europe/Berlin and a
non-DST zone. Do not infer subject or timezone from filenames or server location.

Finance keeps existing inclusive endpoints and date-only UTC start/end semantics
from `Service#timestamp`; UI labels those explicitly. Offset timestamps are
normalized to UTC. The display timezone does not reinterpret accounting dates.
Use BigDecimal and existing Finance reporting/projection; all monetary/quantity/
rate outputs remain decimal strings with currency/unit. Never calculate balances
in JS, merge native currencies or substitute zero for missing basis/prices.

Automation cron matches all five fields conjunctively, including day-of-month AND
day-of-week. It has no per-schedule timezone. Only report a next due if the operator
supplies the authoritative external runner's execution timezone; evaluate existing
`CronExpression#match?` against minute instants converted into that zone, bounded
to 527,040 minutes (366 days). Otherwise next due/timezone/worker health are unknown.
Configured/enabled does not imply running. Do not alter recurrence or deduplication
semantics. Medication schedules and external calendar events remain separate.

No cross-request derived report cache in the first release. Per-request memoization
and immutable read snapshots are allowed. Internally detect graph/Capture file
drift via stable content fingerprints, Dataset drift through the same open
connection's `PRAGMA data_version` across read transactions plus catalog/version
checks, and runtime drift via content watermarks. Main-file mtime alone misses WAL
commits. Bind multiple sources, compare permitted dependencies before/after, retry once, then return
`partial` with `source_changed` and suppress inconsistent totals. A source too large
to fingerprint within budget returns unavailable; do not silently use stale data.

Expose opaque source versions computed only from permitted dependencies/fields
using a per-process HMAC key, plus explicit freshness timestamps where authoritative.
Keep full internal fingerprints private. Hidden-only edits must not change visible
counts/rankings/versions or invalidate a visible cursor. Authorization epochs change
on policy restart. Independent widgets have separate source versions/computed times;
Home does not claim an atomic cross-widget snapshot. Missing source timestamps are
null; computation time is not source freshness.

Poll only visible tabs every 30s with 60/120/300s failure backoff and jitter up to
10%; stop on logout/expiry, abort obsolete fetches on filter/navigation, and ignore
late results by request generation. Browser abort does not guarantee Gateway job
cancellation. Reloading reads current source versions; event delivery is optional.

## Synthetic acceptance and performance budgets

Use seed `dashboard-p0-v1`, fixed `2026-10-25T12:00:00Z`, deterministic ULID
sequences, temporary external configuration and temporary arbitrary-named Vaults.
Prepare fixtures through synthetic Engine/approved Dataset workflows; browsing
uses no writer. Fixtures must include:

| Scenario | Required assertions / implementing phase |
|---|---|
| Plain generic, CRM with different schema-declared record folders, Finance without CRM | Feature detection uses SDK metadata, optional absence is honest (P1/P3/P4) |
| Missing parent/DB, engine versions 0/1/2/3/4, malformed catalog, locked/WAL DB, absolute/relative overrides | No create/migrate/repair; WAL rows visible; writer compatibility (P1) |
| Visible and restricted contacts/edges, private email/phone, hidden-only edits | Visible-first search, ranking/traversal independence, identical hidden/not-found errors (P1/P3) |
| Capture kinds, hostile HTML/URLs/Unicode, restricted links, missing Evidence | Literal text, safe references, no external fetch, no hidden counts (P2/P3) |
| FIFO stocks, fees/transfers, loans, two owners/accounts, native currencies, missing basis/marks | Report parity and no truncated accounting input (P4) |
| Two clinical subjects, arbitrary/nonnumeric analytes, incompatible units/methods/specimens, date-only tests | No accidental clinical combination or diagnosis (P5) |
| Failed jobs, absent history/worker timezone, DOM+DOW cron, DST spring/fall | Safe operational metadata, unknown health, original schedule semantics (P6) |
| Login/expiry, forged Host/Origin, CSRF, session/job isolation, external edits, two Vault processes | No canonical writes or cross-context results; installed-package browser smoke (P7) |

Budget dataset: 1,000 entities, 5,000 relationships, 1,000 Captures, 10,000 Finance
events, 10,000 lab rows and 1,000 runtime records; stress fixture scales graph/
Capture/runtime counts 10x and Finance/lab rows to 100,000 each. No real fixtures.
Measure on a documented machine/Ruby/browser with warm filesystem, cache disabled,
five warmups then 30 samples, concurrency 1 and 4, reporting median/p95/max and RSS
delta. Proposed release gates: bounded search/list p95 <=1s; contact ranking <=2s;
10,000-row Finance replay/lab series <=5s; 100,000-row reports finish within the
30s hard deadline or return explicit bounded/unavailable results. No fabricated
partial accounting totals. Overview first usable widget <=2s, all terminal <=30s;
individual failures must not block other widgets. Max JSON response 1 MiB, static
initial assets <=250 KiB uncompressed, process RSS growth <=128 MiB across 30 runs
on the budget fixture. These are reproducible targets, not P0 latency measurements.
P7 records measured results and any approved budget change; a failed gate remains
open. P1 resource/security bounds remain mandatory regardless of timing targets.

## Decisions and next boundary

Dashboard decisions D1-D6: optional companion Rack/WEBrick component; explicit
single Vault per process; in-memory authenticated per-browser Gateway identities;
nonmigrating SDK Dataset facade; typed policy-visible domain reads with no derived
disk cache; explicit timezone with unchanged Finance/cron semantics. These refine
SDK-ADR-003/006/007/010/011/012/013/015/016 without superseding them. Dashboard
session/telemetry memory is operational state outside the Vault; preexisting
runtime artifacts are read sources. No new global ADR is necessary for P0.

P0 ends at these contracts. P1-a implements the read facade/injection and regression
tests first; P1-b adds the optional package and authenticated search vertical slice.
Do not enable a route whose handler has not met its read-safety/privacy gates.
P7 must verify installation on Ruby 2.6.10 and latest stable Ruby (4.0.9 observed
in the evaluation), browser/security/performance gates and both package smokes.
Calendar/reminders, diagnoses, learning milestones, live news/valuations, Hermes/OS
jobs, conversation and mutation UI remain F1-F7, requiring separate authorization.
