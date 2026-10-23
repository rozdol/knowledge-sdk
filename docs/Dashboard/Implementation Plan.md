# Dashboard implementation plan

Status: planned; no dashboard implementation has started.

Prepared: 2026-10-23. Repository baseline inspected: `85a0385`.

This is the implementation specification for separate agentic coding sessions. Read
[Session Guide](Session%20Guide.md) before implementing a phase and update
[Progress](Progress.md) at every handoff. The current repository and its `AGENTS.md`
take precedence over assumptions recorded here.

## Outcome and scope

Deliver an optional, local-first HTML/CSS/JavaScript dashboard for an attached Vault,
using the existing Ruby SDK and Agent Platform as the backend. Hermes remains an
independent client of the same platform; it is not needed to render ordinary pages.

The first release is read-only with respect to canonical knowledge. It displays
existing contacts, Captures, financial reports, laboratory history, KG schedules,
jobs, and notifications. Missing plugins, schemas, permissions, or data produce an
honest unavailable or empty state. Browsing never installs plugins, creates
Datasets, migrates storage, creates proposals, or submits Intents.

The navigation covers all six requested categories. It must not imply that the
first release implements calendar synchronization, diagnosis management, learning
tracking, news feeds, or Hermes/system job inventory. Those are explicit follow-up
increments below. No fake data is shown outside a clearly labeled synthetic demo.

### First-release coverage

| Requested area | First-release behavior | Deferred capability |
|---|---|---|
| Calendar / events / reminders / alerts / schedules | Existing policy-visible dated records where supported; KG automation schedules, notifications, and run status; separate agenda and automation views | Calendar connector, general reminder lifecycle, Hermes/system cron inventory |
| Finance | Owner-scoped assets, liabilities, net worth, transactions, and supported investment P&L | Asset news, live quotes/FX, household/business P&L extensions |
| Medical | Blood-test history, analyte trends, units, source references, laboratory intervals and flags | Formal diagnosis/encounter timeline and management |
| Contacts | Search, deterministic top 10 with reasons, bounded relationship view, contact detail | Manual importance controls and other edits |
| Memory / lifestyle | Capture search, recent Captures, separate knowledge-change Activity | A general personal-occurrence model beyond already supported records |
| Learning / research | Searchable existing topics/resources where metadata permits; progress explicitly unavailable without milestones | Learning goals, milestones, sessions, assessed progress |

Investment P&L is the initial Finance meaning. Do not silently present it as a
complete household cash-flow statement, business income statement, or tax report.

## Architecture and nonnegotiable boundaries

```text
Browser (HTML + CSS + JS modules)
  -> optional Ruby HTTP host / presentation API
  -> policy-filtered discovery and opaque-token Gateway invocation
  -> existing SDK services / trusted registered read capabilities
  -> canonical Markdown and Dataset SQLite, plus derived/runtime services

Hermes -> its existing adapter -> the same Gateway capabilities
Existing scheduler/worker -> existing orchestration; independent of browser
```

- Keep graph semantics and calculations in their existing subsystems. HTTP routes
  perform transport validation and presentation composition only. No subprocess
  calls to `kg`, arbitrary SQL API, arbitrary filesystem API, or second writer.
- Register missing reads through SDK-owned manifests and handlers. A capability
  selector is never authority; resolve current discovered contracts and use their
  opaque invocation tokens. Keep capability tokens server-side in this UI design.
- Use a distinct dashboard identity, explicit permission allow-list, and Gateway
  `read_only` environment. Do not reuse `local_cli_identity` or its `*` permissions.
  The web host does not expose a generic unrestricted capability-execution route.
- Treat imported text as hostile data. Render text safely; never insert imported
  HTML or execute scripts, templates, policy, or configuration from a Vault.
- Canonical graph identities/relationships and Captures remain Markdown. Rows stay
  in the existing Dataset store. Do not add editable balance/contact/diagnosis
  mirror tables. Cache only expensive derived reports, not raw graph fact copies.
- Preserve Ruby 2.6 and `KnowledgeGraph::Engine` compatibility. New web lifecycle
  belongs under `KnowledgeSDK`. Optional web dependencies must not become required
  for existing CLI users. An incompatible dependency requires a documented design
  resolution; it does not authorize changing the supported Ruby version.
- Resolve one explicitly selected Vault per server process for the first release.
  This avoids process-global Dataset/configuration overrides leaking across Vaults.
  Do not accept arbitrary Vault paths from the browser or mutate the active registry
  during a request. All attached Vault names/layouts remain valid.
- Authenticated sessions, bounded telemetry, and optional derived runtime artifacts
  may change operational state. Enumerate these effects; canonical browsing remains
  nonmutating. No automatic runtime initialization inside an attached Vault solely
  to make an unavailable widget appear ready.

## Verified starting points and gaps

| Area | Existing code/contracts to inspect | Planning implication |
|---|---|---|
| Gateway and transports | `lib/agent_platform/{bootstrap,gateway,policy,services,handlers}.rb`, `lib/agent_platform/adapters/rest.rb`, `test/agent_platform/` | REST adapter returns Ruby response hashes; HTTP hosting, browser login, and static assets are missing |
| Entity and relationship reads | `config/agent_platform/manifests/core-read.json`, `lib/knowledge_intelligence/` | Reuse search and paths; verify bounded lists, privacy-safe ranking, and schema availability |
| Captures | `lib/knowledge_capture/`, `config/agent_platform/manifests/captures.json`, `test/capture/` | Search exists; recent/detail contracts may need additions |
| Finance | `lib/knowledge_finance/{reporting,projection,integrations,conversation}.rb`, Finance docs, `test/finance/` | Reports exist; current `kg.finance.read` accepts conversational content, so widgets need typed read contracts that reuse calculations |
| Health/Datasets | `lib/structured_dataset/`, Health docs, `config/agent_platform/manifests/datasets.json`, `test/dataset/` | Current public Dataset query is a supported natural-language query, not an arbitrary typed table browser |
| Dataset initialization | `lib/structured_dataset/engine.rb`, `lib/structured_dataset/database.rb` | Engine construction currently calls `migrate!`; database connections create directories and configure WAL. A read path must not accidentally provision or migrate storage |
| Activity | `lib/knowledge_activity/`, `test/activity/` | Human-oriented change history exists; expose safe reads rather than calling CLI or creating another Activity store |
| Automation | `lib/knowledge_orchestration/{scheduler,runtime,engine}.rb`, orchestration docs, `test/orchestration/` | Scheduling/jobs exist; public list/status reads need discovery contracts. Current schedule definition does not carry a per-schedule timezone |
| Async operations | `lib/agent_platform/jobs.rb`, `lib/knowledge_orchestration/runtime.rb` | Gateway jobs are in memory; orchestration jobs are durable. Do not promise restart recovery for the former |
| Cache | `lib/knowledge_orchestration/cache.rb` | Existing snapshot dependency alone is insufficient for Dataset-only changes or permission changes; include additional signatures or leave caching off |

These are observations at the baseline, not substitutes for inspecting current code.

## Shared contracts to freeze in P0

### Presentation API

Use a versioned `/api/v1` browser API. The names below are proposed routes, not
existing product commands or permission to bypass Gateway discovery.

| Route family | Responsibility |
|---|---|
| `/session`, `/session/login`, `/session/logout` | Authenticated identity, configured display context, login/logout; never secrets or storage paths |
| `/dashboard/availability`, `/dashboard/overview` | Permitted feature availability and independent widget results |
| `/contacts`, `/contacts/top`, `/contacts/:id`, `/contacts/:id/relations` | Bounded contact search, ranking, detail, relationships |
| `/captures`, `/captures/:id`, `/activity` | Capture reads and separate knowledge-change history |
| `/finance/scopes`, `/finance/net-worth`, `/finance/positions`, `/finance/liabilities`, `/finance/transactions`, `/finance/pnl` | Explicit owner/account/time filters and existing Finance results |
| `/health/labs`, `/health/labs/series` | Subject/panel/analyte/date filtering, rows and trends |
| `/automation/schedules`, `/automation/jobs`, `/notifications` | Redacted KG operational status; no run/enable/cancel/ack actions |
| `/jobs/:id` | Owned asynchronous read-operation result; distinct from durable automation jobs |

Dashboard data routes use GET. Login/logout use POST with appropriate request-origin
and CSRF protection. Read-only capability execution may internally use POST without
granting canonical-write authority. No approval, proposal creation/submission, source
fetch, schedule mutation, or plugin-install endpoint ships in the first release.

Define one explicit widget envelope: contract version, request ID, status, data,
warnings, scope, requested time window, computation timestamp, source timestamps,
completeness/limitations, and safe evidence references. Distinguish `ok`, `empty`,
`partial`, `unavailable`, `stale`, and `error`; do not use an empty array to hide a
failure. Loading is a frontend state, not a completed server result.

HTTP 202 represents queued work with a job reference. Specify authentication,
forbidden/not-found, invalid input, conflict, rate-limit, and timeout behavior.
Do not expose hidden object existence through different error responses or counts.
Capability/feature availability is policy-filtered. Totals and rankings operate on
visible records, not on hidden records followed by redaction.

Freeze limits, stable sort tie-breakers, opaque cursor pagination, maximum date
window, graph node/edge bounds, timeouts, and cancellation of obsolete UI requests.
Cursor contents must be validated and bound to scope/filter/authorization versions.
Do not turn widget filters into natural-language prompts with fragile parsing.

### Privacy, authentication, and deployment

- Bind to loopback by default. Require an operator-provisioned secret to establish
  a browser session; locality alone is not authentication. Keep bootstrap secrets
  out of URLs, frontend bundles, logs, and committed files.
- Use server-managed expiring sessions, HttpOnly/SameSite cookies, CSRF/origin checks,
  Host allow-listing against DNS rebinding, login throttling, and bounded requests.
  Use Secure cookies under TLS. No permissive CORS. No unauthenticated data routes.
- Remote/LAN serving is outside the initial release. Document a future HTTPS/auth
  deployment design rather than silently widening the bind address.
- Enforce domain and restricted permissions at the Gateway handler, including
  related entities, Dataset/row sensitivity, evidence, totals, search and ranking.
  Private contact points require the existing private-contact permission. Do not
  invent permission strings without registering and documenting their semantics.
- Respect existing leak guards. Return permitted structured fields and safe record
  references, not Vault paths, local Evidence paths, raw Markdown, or arbitrary
  attachment contents. A missing evidence-preview capability shows a safe reference.
- Send `Cache-Control: no-store` for sensitive browser responses; avoid payloads in
  localStorage, IndexedDB, service workers, browser URLs and referrers. Bound any
  temporary in-memory state and clear it on logout/context change. Avoid query text
  and identifiers in access logs. Self-host assets with a restrictive CSP.
- No external model calls, external telemetry, or remote assets are needed for the
  read-only release. Restricted information never leaves the local trust boundary.

### Time, precision, and provenance

- Use explicit `as_of`, subject/owner, date range, and timezone inputs. Resolve IANA
  timezone handling in P0; test daylight-saving boundaries. Use the configured user
  timezone, not a hardcoded geographic assumption or the execution host default.
- Preserve date-only clinical dates and all-day event dates as dates. Define filter
  boundaries per domain rather than changing existing inclusive Finance semantics.
  Keep occurrence/test/effective time separate from recorded/imported/computed time.
- Preserve financial decimal strings and currency; calculate with existing Ruby
  decimal logic. Chart coordinates may be approximate, but labels/tables retain
  exact authoritative values. No JavaScript accounting or float-based totals.
- Every widget identifies source freshness and limitations. A missing price, basis,
  source timestamp, timezone, target, or scheduler heartbeat is unknown, not zero
  or healthy. Do not infer diagnosis, causation, mastery, or successful job execution.
- Initially compute on demand. Enable expensive-report caching only with a key that
  includes Vault identity, effective authorization/policy, filters, capability version,
  graph snapshot, Dataset signature, and relevant runtime watermark. Recheck versions
  for external Obsidian/Dataset edits; event delivery alone is insufficient.
- Cross-widget atomic snapshots are not assumed. Expose per-widget source versions;
  a report requiring multiple sources must detect concurrent drift and retry within
  a bound or return an explicit inconsistent/partial result.

## Delivery phases

Run phases in order. Each phase has its own coding-session handoff. Split the
suggested session units when necessary; do not call incomplete work complete.

### P0 — Contract and dependency preparation

Dependencies: none. Session units: P0-a architecture/contracts; P0-b dependency and
read-side-effect evaluation. This phase produces design artifacts, not web features.

Tasks:

1. Reconcile this plan with current manifests, permissions, readers, plugin detection,
   Dataset version handling, configuration overrides, and tests.
2. Write `docs/Dashboard/Architecture.md` and `docs/Dashboard/API Contract.md` with
   concrete response examples, route methods, bounds, permissions, error semantics,
   source versioning, auth flow, and read-only guarantees. Add ADRs if needed.
3. Choose exact Ruby-compatible Rack/server dependencies and optional installation
   packaging. Prefer a small Rack app; use Puma if the evaluated version fits the
   compatibility and maintenance requirements. Record minimum/latest Ruby checks.
4. Choose asset packaging, browser-test tooling, time-zone support, and deterministic
   synthetic fixture scenarios. Node tooling, if used, is development-only.
5. Design an SDK-level nonmigrating read mode/facade for existing Dataset storage.
   Missing/outdated storage returns unavailable/upgrade-required. No page request
   may call implicit Dataset migrations. Preserve existing write behavior.
6. Define how schema/profile differences are detected without hardcoding a Vault's
   folders or assuming CRM, Finance, or Health is installed. Record unsupported
   features and future increments explicitly.

Exit: contracts and dependency decisions are concrete enough to implement without
inventing storage/auth semantics; all first-release routes have an existing or
planned Gateway capability mapping. Mark any truly unresolved release blocker.

### P1 — Optional HTTP host and authenticated read boundary

Dependencies: P0. Session units: P1-a read-safe SDK primitives; P1-b web transport/auth.

Tasks:

1. Implement the approved read-safe Dataset access path in the owning subsystem,
   using its existing schema/query logic. Routes never open SQLite themselves.
   Avoid graph Engine/write initialization for reads. Honor Dataset path overrides.
2. Add optional `KnowledgeSDK` web lifecycle/host loading and the documented launch
   command, proposed as `kg dashboard serve --vault PATH`; freeze its syntax in P0.
   Resolve the Vault once; no change to attach, detach, init, or Engine defaults.
3. Implement loopback HTTP serving, static-asset boundary, login/logout/session,
   request bounds, Host/origin policy, CSRF defenses and safe logging.
4. Build the restricted dashboard Gateway identity and generic internal discovery
   bridge; handle stale invocation tokens through bounded rediscovery. Expose
   availability and one existing bounded entity-search route for a vertical test.
5. Provide safe error serialization and owned-job access. Document in-memory job
   expiry/restart behavior and run one web process initially; never return another
   identity's job. Do not add a scheduler inside each HTTP worker.

Exit: authenticated synthetic search works end to end; anonymous, wrong-origin,
wrong-Host, out-of-scope and write-capability requests fail safely. Starting/browsing
without Datasets or with an older schema does not create/migrate canonical storage.
CLI still works with the web component absent.

### P2 — Browser shell and shared widget behavior

Dependencies: P1. Session units: P2-a shell/API client; P2-b component and browser QA.

Tasks:

1. Add HTML/CSS and JS modules with Home plus all six category routes, responsive
   navigation, login, safe session state, and a shared detail/evidence drawer.
2. Implement API client, abortable requests, bounded pagination, filters, widgets,
   loading/empty/partial/stale/error states and independent widget failures.
3. Connect the existing search vertical slice; use explicit unavailable states for
   unimplemented pages. Do not quietly substitute synthetic production responses.
4. Provide accessible keyboard navigation, labels, readable tables, reduced-motion
   behavior, and responsive layouts. Choose a small self-hosted chart library only
   where needed; retain table alternatives and license notices.

Exit: real synthetic-Vault data passes through the HTTP/Gateway path into the UI;
navigation, session expiry and hostile strings work at desktop and mobile widths.
No imported content is interpreted as HTML or executable Markdown.

### P3 — Contacts, memory, and bounded search

Dependencies: P2. Session units: P3-a SDK read contracts; P3-b page integration.

Tasks:

1. Reuse entity search, safe entity detail, paths/network and relationship-health
   calculations. Add only missing typed read contracts through the registrar.
2. Define deterministic top-10 ranking with a versioned formula, visible reasons,
   a stable ID tie-breaker and visible-record-only inputs. Use existing interaction
   signals; absent signals remain unavailable. No new editable ranking metadata.
3. Add permitted recent/detail Capture reads as needed, plus Activity list/search
   reads. Preserve existing Capture immutability and Activity projection semantics.
4. Show personal occurrences only where supported and clearly separate them from
   knowledge-change Activity and Capture creation time. Search existing research
   resources/topics through metadata; do not manufacture learning progress.
5. Bound contact graph traversal and pagination. Federated search reports each
   source's result state without summing duplicate identities across sources.

Exit: contact ranking/search/detail/relations and Capture/history views are usable;
fixtures prove restricted nodes, private points and hidden counts do not leak.
Missing CRM/profile metadata has a useful unsupported state.

### P4 — Finance reports and transactions

Dependencies: P3. Session units: P4-a typed Finance contracts; P4-b UI and accounting QA.

Tasks:

1. Add typed owner/account/date/currency report capabilities that call existing
   Finance services. Keep existing conversational `kg.finance.read` compatible.
   Do not interpolate filter values into natural-language query strings.
2. Expose permitted scope selection, positions, cash/assets/liabilities, net worth,
   immutable transactions, and supported investment P&L. Preserve complete-history
   replay; pagination of a transaction display must not truncate accounting input.
3. Preserve exact-decimal JSON, native currencies, explicit FX availability,
   missing basis/marks and instrument limitations from existing reports.
4. Add Finance tables and charts, explicit owner/account/range controls, evidence
   references and freshness. Do not add automatic price or news fetches.

Exit: UI totals match existing SDK reports on synthetic stocks, transfers, fees,
loans, multiple owners and missing-valuation scenarios. Native currencies are not
summed into a fictional total; restricted identities/rows cannot influence totals.

### P5 — Laboratory history and trends

Dependencies: P4. Session units: P5-a typed lab reads; P5-b UI and clinical-data QA.

Tasks:

1. Add read capabilities for filtered laboratory rows and analyte series using
   existing Dataset/template semantics. Scope to an explicit subject when needed;
   do not combine different people's observations or infer ownership from filenames.
2. Preserve panel, analyte, value, unit, original reference interval/flag, specimen,
   laboratory, test date and permitted Evidence references. Support nonnumeric
   results in tables; do not force them into numerical charts.
3. Keep incompatible units/methods/specimens separate unless a trusted existing
   conversion explicitly supports combining them. Do not invent clinical ranges.
4. Add timeline/table/chart views and an explicit diagnosis-unavailable state.
   No diagnosis, treatment recommendation, document upload or OCR pipeline here.

Exit: arbitrary analytes work without physical schema changes; mixed units,
nonnumeric values, date-only tests and sensitive subjects display correctly.
No database/template provisioning or migrations occur on visit.

### P6 — KG automation, overview, and refresh

Dependencies: P5. Session units: P6-a operational reads/time semantics; P6-b home/refresh.

Tasks:

1. Register read capabilities for configured KG schedules, durable workflow jobs,
   safe run summaries and notifications. Read only SDK-owned trusted configuration
   selected by the operator. Never load executable/config files discovered in notes.
2. Label source and semantics explicitly. A configured/enabled schedule is not proof
   that a worker is alive. Last run, next due, worker health and timezone are unknown
   unless supported by an authoritative value or deterministic validated calculation.
3. Preserve current cron behavior, including its existing day-field matching
   semantics. The current format has no per-schedule timezone: report actual
   execution context and do not reinterpret schedules in browser-local time. A
   timezone schema extension, if required, needs an additive reviewed contract and
   DST tests; do not silently change scheduling while building a status page.
4. If exposing next due, use the scheduler's existing matching semantics with a
   bounded search. Return unavailable when no match is found within that bound.
   Keep medication recurrence separate from automation cron and calendar events.
5. Compose Home from independent existing widgets, limited notifications and
   supported dated records. Label the absent calendar integration; no manufactured
   upcoming appointment list. Include links to detailed category views.
6. Add bounded visible-tab polling with backoff and abort on navigation/logout.
   Refresh source versions after external edits. Enable derived report caching only
   if the full dependency/authorization key and invalidation tests are implemented.
   SSE is optional future work, not a release prerequisite.

Exit: scheduling continues under its existing external runner while the browser is
closed; browsing cannot run or alter jobs. Slow/failed widgets leave other widgets
usable. External edits refresh or visibly invalidate affected reports. Hermes and
OS jobs remain explicitly not connected.

### P7 — Integrated verification, packaging, and first release

Dependencies: P6. Session units: P7-a acceptance/security/performance; P7-b docs/package.

Tasks:

1. Add a synthetic dashboard acceptance scenario covering optional-plugin absence,
   generic and CRM Vaults, Finance/Health data, missing/old Dataset storage, configured
   Dataset overrides, permissions, failed jobs and external edits. Separate instances
   pointed at two Vaults must remain isolated.
2. Test login/session expiry/logout, DNS rebinding/origin/CSRF defenses, traversal,
   XSS payloads, oversized queries, unauthorized job IDs, hidden counts, and cached
   authorization changes. No approval, canonical-write, or external-model route may
   be reachable with the dashboard identity.
3. Test nonmutation by comparing canonical note bytes and logical Dataset schemas/
   rows before and after browsing; do not compare live SQLite main-file bytes in
   isolation from WAL. Assert no DB/directory creation for missing storage and no
   migration for outdated storage. Allow only documented operational side effects.
4. Check representative desktop/mobile layouts, keyboard flows, source evidence,
   mixed timestamps, large bounded results and per-widget failure recovery.
   Establish reproducible synthetic performance budgets in P0 and report results;
   avoid promising exact latency before measuring.
5. Package static assets and optional server dependencies correctly; smoke-test an
   installed gem/component from a temporary directory without the source checkout.
   Verify current CLI installation without web extras and the supported Ruby matrix.
6. Update product/developer/install/configuration documentation, schemas/manifests,
   examples, limitations and migration guidance as required. Document start/stop,
   authentication, Dataset upgrade-required recovery, optional plugins and recovery
   from lost in-memory jobs. Do not claim deferred domains are complete.

Exit: required repository checks, browser checks and installed-package smoke pass;
the first-release scope above is met and every remaining limitation is explicit.
Creating a release/tag, publishing a gem, deployment, or accessing a real private
Vault is a separate user-directed action, not part of marking this phase complete.

## Verification gates for every implementation session

Run the smallest relevant subsystem test while developing. Before handing off a
completed product change, run the repository's required checks:

```sh
bundle exec rake test
ruby acceptance/test_acceptance.rb
```

For cross-subsystem, migration, performance, or release work, also run:

```sh
ruby acceptance/run_acceptance.rb --run-id run_<26-character-ULID>
```

Replace the placeholder with a newly generated valid ULID. Do not reuse the literal
placeholder. Build when dependencies, packaging, entry points or root docs change:

```sh
gem build knowledge-sdk.gemspec
```

Review the full diff, `git diff --check`, and `git status`. Keep generated gems,
browser profiles, acceptance Vaults, databases, runtime state and credentials out
of commits. Record exact commands, outcomes and unrun checks in Progress. Do not
mark completion when required checks are failing or unavailable. Use only synthetic
fixtures; never copy private attached-Vault contents into tests or screenshots.

## Follow-up increments after the read-only release

These preserve the full requested direction but are outside P0-P7. Each needs a
fresh scoped implementation session and its own concrete contracts/tests.

| ID | Increment | Required design and acceptance boundary |
|---|---|---|
| F1 | Calendar, personal events and reminders | Explicit event identity/source, occurrence vs recorded time, IANA timezone/all-day dates, recurrence exceptions, cancellations, source deduplication and sync cursor. External reads may remain derived; canonical persistence uses approved Intents. Reminder delivery has one scheduler owner and delivery/idempotency rules. |
| F2 | Diagnoses and clinical encounters | Approved opt-in schema/template, subject/provider/source/date, documented vs suspected/resolved states, immutable provenance and restricted permissions. Laboratory flags never become diagnoses automatically. |
| F3 | Learning/research progress | Topic/goal/milestone/session model through existing SDK extension mechanisms; progress derives from explicit completed/total criteria or assessments. No target means activity/coverage, not invented mastery. |
| F4 | Asset news and optional valuations | Public instrument identifiers only, provider credentials outside Vault content, bounded hostile-source fetching, publication/source timestamps, attribution, deduplication and expiry. No balances/quantities sent outward. Saved canonical records and valuation observations require existing approved Intent paths. |
| F5 | Hermes and system job inventory | Verify actual external APIs first; separate read adapters, source labels, permissions, health and timezone semantics. No hardcoded Hermes paths, shell execution interface, or schedule enable/run actions. |
| F6 | Hermes conversational panel | Explicit configured Hermes bridge, session ownership, permitted evidence references and local/external model routing policy. Restricted content stays local. Answers identify evidence/uncertainty and do not replace deterministic widgets. Proposed changes remain review-only. |
| F7 | Dashboard editing and review | Separate threat/design review for proposal creation, exact diff review, approval and submission roles. Every canonical action remains an immutable Intent through the current Engine; no autosubmission. Operational controls also need separately scoped authority. |

After P7, the suggested order is F1, F2/F3, F4/F5, F6, then F7 if requested. These
IDs are roadmap labels, not automatic authorization to implement or operate external
integrations, contact others, publish, or edit a private Vault.
