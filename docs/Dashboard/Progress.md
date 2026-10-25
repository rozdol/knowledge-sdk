# Dashboard implementation progress

Source of truth for execution: [Implementation Plan](Implementation%20Plan.md).
Session workflow: [Session Guide](Session%20Guide.md).

Updated: 2026-10-25. Planning baseline: `85a0385`. P0 inspected revision: `324aed9`.

P0 and P1 are complete. The optional authenticated loopback host, Gateway search,
availability capability and nonmigrating Dataset facade are implemented. The P2
browser application and later domain widgets have not started. Accepted
contracts: [Architecture](Architecture.md), [API Contract](API%20Contract.md), and
[Dependency Evaluation](Dependency%20Evaluation.md).

## Phase ledger

Allowed states: `not_started`, `in_progress`, `complete`, `blocked`.
Use `blocked` here only with a concrete dependency and next action; it is a project
ledger value, not an instruction to change any Codex goal status.

| Phase | Deliverable | Dependencies | Status | Evidence / next action |
|---|---|---|---|---|
| P0 | Contracts, dependency evaluation, read-safety design | None | complete | Architecture/API/dependency artifacts accepted; checks below passed; future runtime/browser gates explicit |
| P1 | Read-safe SDK primitives and optional authenticated HTTP host | P0 | complete | P1-a/P1-b delivered; required checks, real HTTP security tests and installed CLI smoke passed; see session record |
| P2 | Browser shell and shared widget states | P1 | not_started | Next: packaged shell/login/API client using the implemented P1 auth/search routes; preserve strict CSP and unavailable domain states |
| P3 | Contacts, memory and bounded search | P2 | not_started | Wait for shared shell/API |
| P4 | Finance reports and transactions | P3 | not_started | Wait for shared page patterns |
| P5 | Laboratory history and trends | P4 | not_started | Wait for typed domain read patterns |
| P6 | KG automation, overview and refresh | P5 | not_started | Wait for domain widgets |
| P7 | Integrated verification, packaging and first release | P6 | not_started | Wait for first-release features |

Deferred F1-F7 are not scheduled or authorized implementation tasks. Start them
only when requested after checking their own scope and prerequisites.

## Decisions already established

- Start with the canonically read-only release; no new approval or mutation UI.
- Optional Ruby web host, HTML/CSS/JS frontend, same Agent Gateway as Hermes.
- Single configured Vault per process initially; no browser-supplied storage paths.
- Typed capability additions reuse domain services rather than replacing them.
- Missing/outdated Dataset storage must not be created/migrated by browsing.
- Investment/wealth P&L is initial Finance scope; other meanings are deferred.
- KG schedule inventory first; Hermes/OS inventory requires future adapters.
- No public deployment, external connectors, external models or real private data
  are needed to complete P0-P7.

## Accepted P0 decisions

- Optional version-aligned `knowledge-sdk-dashboard` companion under
  `optional/dashboard/`; lazy core CLI loading, no web dependencies for ordinary CLI.
- Rack 3.2.7 / rackup 2.3.1 / WEBrick 1.9.2; Puma native build failed on missing
  system Ruby headers, resolved by selecting the pure Ruby server.
- Required operator secret file, loopback-only single process, expiring in-memory
  sessions and per-browser Gateway identity, explicit allow-lists/read_only policy.
- Separate `StructuredDataset::Reader` / `Database#with_read_connection`; no Engine
  construction, migration or provisioning on dashboard reads. Engine schema 3 only;
  old/new/absent/incompatible storage has explicit unavailable states.
- Typed domain capabilities and planned permission semantics/routes/limits in API
  Contract. Existing conversational APIs remain compatible; register new contracts
  in their owning phases. Visible-only aggregation/traversal and safe field lists.
- TZInfo 2.0.6 / concurrent-ruby 1.3.8 / tzinfo-data 1.2026.5; explicit IANA display
  zone, unchanged inclusive UTC Finance dates and conjunctive scheduler cron semantics.
- Native ES modules/SVG/table alternatives, packaged assets, development-only
  Playwright 1.56.1 / Node 22.13.1, deterministic fixtures and measurable P7 budgets.
- No cross-request report/disk cache; source drift checks, visible-only opaque
  versions, bounded memory cursors/jobs, no Vault runtime initialization.
- Dashboard-local decisions D1-D6 refine existing ADRs; no global ADR superseded.

## Session records

### 2026-10-23 — Planning only

- Created Implementation Plan, Session Guide and this ledger.
- Inspected existing Gateway/REST adapter, policies, Dataset initialization, Finance
  integration, Activity and scheduler boundaries to identify implementation gaps.
- No product code, dependencies, commands, manifests or canonical Vault data changed.
- Validation: a Python documentation check passed for local links, balanced code
  fences, final newlines and matching P0-P7 plan/ledger entries. `git diff --check`
  passed. Per-file `git diff --no-index --check -- /dev/null PATH` emitted no
  whitespace diagnostics (exit 1 represents each new file's addition). Final status
  contains only the new `docs/Dashboard/` directory.
- Product test suites and package build were not run: this session added planning
  documents only, with no product implementation or root-documentation changes.
- Next session: P0-a, followed by P0-b if the design work needs a second session.

### 2026-10-25 — P0-a/P0-b contracts and dependency/read-safety evaluation

- Status after session: **P0 complete**; P1-P7 remain not_started. All six P0 tasks
  and its design exit criteria are covered by the three linked artifacts. This is
  design completion, not a working dashboard release or P1 implementation.
- Starting revision: `324aed9` (`DashBoardPlan`); initial `git status --short` was
  empty. No unrelated user changes existed. No commit created.
- Prerequisites: read AGENTS, README, Architecture, ADRs, all Dashboard planning
  documents; inspected current manifests/policy/Gateway/REST/services/jobs/security,
  Dataset storage/query/integrations, SDK configuration/profile/schema readers,
  Finance/Health/Capture/Activity/orchestration docs and nearest tests. No P0
  Architecture/API document existed before this session.
- Files changed: added `docs/Dashboard/Architecture.md`, `API Contract.md`,
  `Dependency Evaluation.md`; updated Implementation Plan status/links and this
  ledger. No product code, gemspec, Gemfile, manifests, validators, migrations,
  executable entry points or canonical data changed.
- Contracts: versioned `/api/v1`, per-route existing/planned Gateway mapping,
  strict typed parameters, widget envelope/examples, status/error/job/cursor
  semantics, permissions, auth, bounds, precision/time/source versions and recovery.
  Dependency/packaging, storage facade, detection, assets, fixtures and performance
  decisions are concrete enough for P1 without inventing auth/storage semantics.
- Read-safety findings: Engine initializes/migrates storage; connection mkdir/WAL
  and ActivityAdapter migrations/cache writes require explicit read-side injection.
  Finance default Service constructs the writable Engine and its conversational
  handler constructs proposal state. Entity search limits before visibility;
  existing paths calculate before filtering. P1/P3 contracts address those gaps.
  Runtime notification free text lacks sufficient privacy provenance: initial
  inventory returns safe generic metadata. No existing behavior was changed here.
- Privacy evidence: used temporary synthetic SQLite files and public dependency
  metadata/gems only. No real attached Vault, external user integration, model,
  deployment or publication accessed. P0 probes do not exercise product browsing;
  required P1/P7 canonical-nonmutation evidence is specified, not claimed complete.

Verification (all commands executed from the repository unless stated):

| Exact command / probe | Result |
|---|---|
| `ruby -v` | Ruby 2.6.10p210, universal.arm64e-darwin25 |
| `ruby -Ilib -Itest test/agent_platform/gateway_test.rb` | Exit 0; 7 runs, 38 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Ilib -Itest test/dataset/storage_test.rb` | Exit 0; 5 runs, 58 assertions, 0 failures, 0 errors, 0 skips |
| `bundle exec rake test` | Exit 0; 265 runs, 3,124 assertions, 0 failures, 0 errors, 0 skips; 128.424490s |
| `ruby acceptance/test_acceptance.rb` | Exit 0; 4 runs, 8 assertions, 0 failures, 0 errors, 0 skips |
| `ruby acceptance/run_acceptance.rb --run-id run_01M5S4MC9WTK37ZB961NCPJWX1` | Exit 0; PASS: 7,724 base notes, 10 Dataview blocks, 2,000 stress operations; 30 validator invocations, 0 failed stress batches |
| `gem build knowledge-sdk.gemspec` | Exit 0; built knowledge-sdk 17.0.0; existing missing-homepage warning |
| Six selected gems installed locally under `/tmp/knowledge-sdk-dashboard-p0-gems/installed` | Exit 0; exact pins install without native builds; isolated from repository/global gems |
| `GEM_HOME=/tmp/knowledge-sdk-dashboard-p0-gems/installed GEM_PATH=/tmp/knowledge-sdk-dashboard-p0-gems/installed ruby /tmp/knowledge-sdk-dashboard-p0-gems/dependency_probe.rb` | Exit 0; six pinned gems loaded; Rack mock/lint and WEBrick adapter passed; DST 23/25/24h passed. Source is the runnable Ruby block in Dependency Evaluation |
| Synthetic sqlite3 READONLY driver probe | Exit 0; supplied text read; INSERT refused with ReadOnlyException; missing nested DB refused with CantOpenException; parent directory remains absent |
| `python3 -` (inline documentation JSON/link/fence/route/phase consistency check) | Exit 0; 6 Markdown documents, 21 local links, 4 valid JSON examples, balanced fences/final newlines, all 24 planned routes and P0-P7 ledger/plan entries covered |
| `git diff --check` | Exit 0; no whitespace errors |
| `git diff --no-index --check -- /dev/null PATH` for each of Architecture.md, API Contract.md, Dependency Evaluation.md | Exit 1 for each new-file addition; no whitespace diagnostics |

- Existing test output included Ruby indentation/uninitialized-instance-variable/
  unused-variable warnings and Bundler's temporary-HOME notice; no test failure.
- Alternative probe failure: isolated `gem install --local` of nio4r 2.7.5 and
  Puma 6.6.1 exited 1; native extension compiler could not find `ruby/config.h`.
  Selected WEBrick stack installed and passed its probe, resolving the P0 choice.
- Checks not run: Ruby 4.0.9/latest-stable execution, live HTTP/browser/visual QA,
  actual optional-component installed smoke and dashboard performance measurements.
  They require later product code/tooling/runtimes; they are explicit P1/P2/P7 gates,
  not skipped evidence for an implemented feature. No required P0 check remains
  failing. RubyGems support metadata alone is not a latest-Ruby runtime pass.
- Generated full-harness reports, Bundler-created Gemfile.lock and built gem were
  copied/moved to `/tmp/knowledge-sdk-dashboard-p0-gems/verification/`. The six
  tracked reports were restored byte-for-byte from the initially clean HEAD.
  Synthetic acceptance Vault stays outside Git. No generated files are delivered.
- Uncommitted paths to preserve: the five Dashboard documents listed above.
  No release/tag, publish, deploy or commit performed.
- Next unit: **P1-a**. Start in `lib/structured_dataset/database.rb`, `engine.rb`
  and `integrations.rb`: add noncreating READONLY connections/facade sharing existing
  query/schema logic, preserve writer defaults, inject readers through Gateway
  Services and Activity without cached Vault writes. Prove missing/old/new/invalid/
  WAL storage and override safety using synthetic temporary fixtures. Do not add
  the HTTP host until this boundary passes; P1-b follows in a separately scoped unit.

Suggested next-session prompt:

```text
Implement Dashboard phase P1, session unit P1-a only. Read AGENTS.md, the required
root architecture docs, docs/Dashboard/{Implementation Plan,Session Guide,Progress,
Architecture,API Contract,Dependency Evaluation}.md, and nearest Dataset/Gateway/
Activity docs and tests. Preserve the uncommitted P0 documents. Implement the
nonmigrating Dataset Reader/read-connection and additive Gateway/Activity injection
contracts; preserve all existing writer/Engine defaults and approval boundaries.
Use only synthetic data. No HTTP host/frontend, real Vaults or integrations yet.
Run required checks, update Progress with exact evidence, and stop at the P1-a
handoff without starting P1-b, committing, publishing or deploying.
```

### 2026-10-25 — P1-a/P1-b read boundary and optional authenticated host

- Status: **P1 complete**. All P1 exit criteria passed on Ruby 2.6.10; P2 has not
  started. The six-category browser shell remains P2, not an implemented P1 feature.
- Starting revision: `324aed9`. Preserved the five uncommitted P0 Dashboard
  documents; no unrelated source changes existed. No commit created.
- Prerequisites verified: reread required root/Dashboard contracts and inspected
  current Dataset, Gateway, CLI, Activity, identity, job and telemetry code/tests.
  Exact P0 optional dependencies remained installed in an isolated temporary gem
  directory and loaded on the supported minimum Ruby.
- P1-a files/contracts: `lib/structured_dataset/{database,engine,errors,integrations,
  read_operations,reader}.rb`, the subsystem loader, Gateway bootstrap/services,
  Activity Timeline and Dataset tests. Engine shares extracted read semantics;
  writer defaults, approval and transaction behavior are preserved. Reader has no
  writer/migration API and pins report reads to one READONLY/query_only transaction.
  Storage versions 0/1/2/4, missing/corrupt/locked/current/WAL storage and explicit
  overrides are covered. Aborted reads close connections. Activity accepts an
  injected reader and `cache:false`, reporting missing Dataset history explicitly.
- P1-b files/contracts: the 16 files under `optional/dashboard/` provide a separate
  version-aligned gem, packaged information page, strict static allow-list,
  settings/session/bridge/Rack/server modules, availability manifest, exported
  operator-settings/common-envelope schemas, license, tests and development Rakefile.
  Core CLI lazy-loads the companion only for `dashboard serve`. No web dependency
  was added to the core gemspec and its package excludes the optional directory.
- Authorization/privacy: Gateway read_only environment, distinct per-browser
  identity and fixed two-capability allow-list, server-held discovery tokens,
  one stale-token retry, fail-closed writer/proposal services. Entity visibility
  filters apply before redirect collapse/limiting; private email/phone/external-ID
  signals require graph:private; stable ordering is immutable ID. Changes are in
  GraphReader/IdentityResolver/Gateway handler, with additive filter arguments and
  compatible existing request/response schemas. Hidden aliases cannot influence a
  visible redirect result. Search output uses an explicit field allow-list.
- HTTP/session behavior: required operator-only external secret/settings files,
  loopback binding, Host/Origin/CSRF checks, raw duplicate-Host/traversal/header
  defenses, request/rate/concurrency/response bounds, HttpOnly/SameSite cookies,
  idle/absolute expiry and logout revocation. No CORS or external assets/models.
  Logs contain only templates/IDs/status/duration; telemetry has capacity/TTL bounds.
- Gateway jobs/telemetry gained opt-in limits/TTL/cleanup; existing defaults remain
  compatible. P1 admits synchronous contracts only. `/jobs/:id` exposes owned
  metadata with result:null, never raw Gateway results; unknown, other-session,
  expired/revoked jobs return identical 404. A future async route needs a typed
  result adapter before 202 admission; no restart durability is promised.
- Documentation: added Operator Guide and companion README; updated root README,
  Gateway/Dataset/Migration guides, API Contract, Implementation Plan and this ledger.
  No canonical schema, Intent, Engine approval, Vault attachment or plugin install
  behavior changed. Only synthetic temporary Vaults and local loopback requests
  were used; no real Vault or external user integration was accessed.

Exact verification results:

| Command | Result |
|---|---|
| `ruby -Ilib -Itest test/dataset/reader_test.rb` | Exit 0; 5 runs, 43 assertions, 0 failures/errors/skips |
| `ruby -Ilib -Itest test/agent_platform/gateway_test.rb` | Exit 0; 10 runs, 49 assertions, 0 failures/errors/skips |
| `ruby -Ilib -Itest test/activity/timeline_test.rb` | Exit 0; 2 runs, 28 assertions, 0 failures/errors/skips |
| `ruby -Ilib -Itest test/agent_platform/jobs_plugins_test.rb` | Exit 0; 5 runs, 19 assertions, 0 failures/errors/skips |
| `bundle exec rake test > /tmp/knowledge-sdk-dashboard-p1-tests-final.log 2>&1` | Exit 0; 275 runs, 3,189 assertions, 0 failures/errors/skips; 126.783803s |
| `ruby acceptance/test_acceptance.rb` | Exit 0; 4 runs, 8 assertions, 0 failures/errors/skips |
| `ruby acceptance/run_acceptance.rb --run-id run_01M5SCBN8AC663KPM2MRJD3PWE > /tmp/knowledge-sdk-dashboard-p1-acceptance-final.log 2>&1` | Exit 0; PASS: 7,724 base notes, 10 Dataview blocks, 2,000 stress operations |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p0-gems/installed:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 ruby -Ilib -Ioptional/dashboard/lib -e 'Dir["optional/dashboard/test/*_test.rb"].sort.each { \|f\| require File.expand_path(f) }'` | Exit 0; 9 runs, 172 assertions, 0 failures/errors/skips; includes real HTTP login/search, raw Host/header/traversal defenses, sessions/CSRF/throttling, old/missing DB, jobs, configuration and response-schema checks |
| `gem build knowledge-sdk.gemspec` | Exit 0; knowledge-sdk 17.0.0 built |
| `gem build knowledge-sdk-dashboard.gemspec` (cwd `optional/dashboard`) | Exit 0; knowledge-sdk-dashboard 17.0.0 built |
| `gem install --local knowledge-sdk-17.0.0.gem --install-dir /tmp/knowledge-sdk-dashboard-p1-install --ignore-dependencies --no-document` and corresponding companion install from its directory | Exit 0 for each; isolated local install only |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p1-install:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 ruby /tmp/knowledge-sdk-dashboard-p1-install/bin/kg version` (cwd `/tmp`) | Exit 0; core 17.0.0 works without web extras |
| Same core-only environment, `ruby /tmp/knowledge-sdk-dashboard-p1-install/bin/kg dashboard serve` before companion install | Expected exit 2; explicit optional-component installation instruction, no Vault resolution/write |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p1-install:/tmp/knowledge-sdk-dashboard-p0-gems/installed:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 ruby /tmp/knowledge-sdk-dashboard-p1-installed-smoke.rb` (cwd `/tmp`) | Exit 0; installed CLI started/stopped cleanly, authenticated search/availability worked outside checkout, packaged schemas present, canonical bytes unchanged, Dataset absent, logs sanitized |
| `python3 -` (changed/new-file syntax, Markdown/link/JSON and artifact checks) | Exit 0; 29 Ruby syntax checks, 11 Markdown files, 42 local links, 5 JSON examples, 3 JSON contract files; all new-file whitespace checks passed and no generated reports/lock/gems remain in the change set |
| `git diff --check`, complete diff review and `git status --short` | Exit 0 for whitespace check; reviewed the full change set; only intended P0/P1 source/docs/tests remain |

- Initial focused failures were corrected before final checks: synthetic weight
  fixture used the wrong date column; minimum Ruby lacks OpenSSL's newer comparison
  helper (now uses Rack's compatible constant-time helper); real WEBrick normalizes
  REQUEST_URI to an absolute URI (the bounded adapter now retains the raw target);
  macOS temporary-directory symlinks required canonical path assertions in tests.
  No required check remains failing. Existing Ruby warnings and gem missing-homepage
  warnings remain; these did not fail verification.
- Read-safety evidence includes unchanged canonical bytes during real HTTP/installed
  search, absent `.knowledge`/DB creation in generic browsing, unchanged older DB
  bytes, READONLY mutation rejection, WAL-visible committed rows, stable read
  snapshots and no Activity cache/directory writes with injected read mode.
- Limitations/future gates: only Ruby 2.6.10 was executable here; latest stable Ruby
  remains a P7 matrix gate. P1 has no browser app/visual QA, report cache, typed domain
  widgets, async user-job admission, remote serving, multi-Vault process, external
  integrations or scheduler runner. Those are not represented as working features.
  Full clinical/Finance privacy and performance/browser acceptance remain their
  owning phases and P7. All P1-specific functional/security exit criteria passed.
- Generated six acceptance reports were saved outside Git and restored from the
  initially clean HEAD; generated gems and Gemfile.lock were moved outside the
  repository to `/tmp/knowledge-sdk-dashboard-p1-verification/`. Preserve all
  current P0/P1 source/docs/tests changes. No publication,
  deployment, commit or P2 implementation occurred.
- Next unit: **P2-a**. Start from `optional/dashboard/assets/index.html`, the App's
  static allow-list and implemented session/search API. Add packaged HTML/CSS/ES
  modules, login/API client and six-category shell with independent widget states;
  add only trusted packaged asset routes. Keep unsupported domain APIs unavailable
  until P3-P6. Introduce the pinned development-only Playwright lockfile/tooling and
  real browser tests without weakening CSP or read-only Gateway authority.

Suggested next-session prompt:

```text
Implement Dashboard phase P2, starting with P2-a. Read AGENTS.md, the required root
docs, Dashboard plan/session/progress/architecture/API/dependency/operator docs and
P1 source/tests. Preserve all uncommitted P0/P1 changes. Build the packaged shell,
login/API client and shared widget states over the existing authenticated P1 read
API. Keep missing domain widgets honestly unavailable; no new canonical writes,
external integrations or real Vault data. Run required repository and browser
checks, update Progress with exact evidence, and stop at the P2 handoff without
starting P3, committing, publishing or deploying.
```

### Template — copy for each implementation session

```text
Date / phase / session unit:
Status after session:
Starting revision and unrelated user changes preserved:
Prerequisites verified:
Implemented behavior / files changed:
Contracts, permissions, schema or dependency decisions:
Canonical-read-safety and privacy evidence:
Verification commands and exact results:
Required checks not run / failures:
Known limitations or blockers and resolution:
Commit reference (only if made) / uncommitted paths to preserve:
Next session unit and concrete starting point:
Suggested next-session prompt:
```
