# Dashboard implementation progress

Source of truth for execution: [Implementation Plan](Implementation%20Plan.md).
Session workflow: [Session Guide](Session%20Guide.md).

Updated: 2026-10-25. Planning baseline: `85a0385`. P0 inspected revision: `324aed9`.

P0-P5 are complete. The optional browser includes policy-visible Contacts,
Captures, Knowledge Activity, independent bounded search, typed Finance reports
with explicit owner/account selection and subject-scoped laboratory history/trends.
P6 has not started. Accepted
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
| P2 | Browser shell and shared widget states | P1 | complete | 28 browser checks, required SDK/acceptance checks, visual inspection and installed asset/CLI smoke passed |
| P3 | Contacts, memory and bounded search | P2 | complete | Seven typed read capabilities, visible-only ranking/traversal, cursor/privacy/window tests, 40 browser checks, required SDK/acceptance checks and installed-package smoke passed |
| P4 | Finance reports and transactions | P3 | complete | Six typed Finance reads, explicit scopes, exact tables/native-currency charts, accounting/privacy/nonmigration tests, browser matrix and installed-package smoke; evidence below |
| P5 | Laboratory history and trends | P4 | complete | Two typed laboratory reads, explicit subjects, original numeric/text results and intervals, separate series, Medical table/timeline/charts; exact evidence below |
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

### 2026-10-25 — P2-a/P2-b browser shell and shared widget behavior

- Status after final review: **P2 complete**; its exit criteria and all required
  checks passed. P3 remains not_started. No commit, publish or deployment performed.

- Starting revision: `31dc14f` (`DashBoard P1`), clean worktree. P0/P1 were committed
  before this session; no unrelated changes existed. Required contracts, subsystem
  source/tests and P1 verification evidence were checked before edits.
- Delivery: package-owned HTML/CSS/native ES modules provide login, Home, Search
  and all six category routes. Responsive navigation, filter controls, literal-text
  result tables, keyboard/focus behavior and the record/evidence dialog are present.
  Domain pages explain unavailable features without fake records, numbers or charts.
  Home search and availability operate independently on real policy-filtered SDK
  reads, not production substitutes. No P3 capability or domain calculation added.
- Files: `optional/dashboard/assets/{index.html,api.js,app.js,widgets.js,styles.css,
  mark.svg}`, the new `lib/knowledge_sdk/dashboard/assets.rb`, host App/loader,
  companion HTTP tests, development-only package.json/package-lock.json and
  Playwright config/fixtures/specs. Updated root/companion README, Operator Guide,
  API Contract, implementation status, this ledger and artifact ignore rules.
- Static contract: only eight known page routes and five content-hashed SDK asset
  URLs are served. Module dependency URLs participate in the app hash. No arbitrary
  path joining, Vault templates, raw HTML imports, CDN, fonts, model calls or Node
  runtime dependency. Strict CSP/no-store/Host/Origin/CSRF protections remain intact.
- Session/client contract: CSRF/session metadata is memory-only. Search filters never
  enter page history or browser storage. Requests abort on navigation/filter/logout,
  with generation checks against late results. `X-Dashboard-Session-Expires-At`
  exposes server expiry to the client without changing TTLs; expiry revalidation
  does not touch idle time. Failed logout clears private DOM and offers explicit
  revocation retry instead of silently reopening an authenticated view.
- Shared widgets handle loading/ok/empty/partial/unavailable/stale/error, warnings,
  completeness, computation vs source timestamps/versions, date-only values and
  permitted source references. The drawer uses textContent and no attachment fetch.
  Shared page controls cap future cursor navigation at five pages. Current P1
  search has no cursor, so Previous/Next stay disabled; filters/25/50/100 bounds
  refine the actual supported read. No backend pagination was invented.
- Tooling: Playwright 1.56.1 is locked as a development dependency on Node 22.13.1.
  Tests use Chromium 141.0.7390.37 (build 1194), Firefox 142.0.1 (build 1495), one
  worker, 1440x900 and 390x844. Every browser test starts an independent synthetic
  Vault/host, checks unchanged canonical file hashes and missing Dataset storage,
  and cleans up. The test-only clock file never enters product code or HTTP routes.

Verification:

| Exact command / check | Final result |
|---|---|
| `bundle exec rake test > /tmp/knowledge-sdk-dashboard-p2-core-tests.log 2>&1` | Exit 0; 275 runs, 3,189 assertions, 0 failures/errors/skips; 136.222534s |
| `ruby acceptance/test_acceptance.rb` | Exit 0; 4 runs, 8 assertions, 0 failures/errors/skips |
| `ruby acceptance/run_acceptance.rb --run-id run_01M5SFEEMT5YF0FBK2P2HVTTT8 > /tmp/knowledge-sdk-dashboard-p2-acceptance.log 2>&1` | Exit 0; PASS: 7,724 base notes, 10 Dataview blocks, 2,000 stress operations |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p0-gems/installed:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 ruby -Ilib -Ioptional/dashboard/lib -e 'Dir["optional/dashboard/test/*_test.rb"].sort.each { \|f\| require File.expand_path(f) }'` (checkout root) | Exit 0; 10 runs, 239 assertions, 0 failures/errors/skips; tests include asset hashes/imports/MIME, page allow-list, path/query/method denials and existing P1 read/auth safeguards |
| `npm_config_cache=/tmp/knowledge-sdk-dashboard-p2-npm-cache npm install --prefix optional/dashboard --ignore-scripts --no-audit --no-fund` | Exit 0; four development-only packages installed; exact Playwright version/integrities retained in package-lock.json |
| `PLAYWRIGHT_BROWSERS_PATH=/tmp/knowledge-sdk-dashboard-p2-browsers node optional/dashboard/node_modules/playwright/cli.js install chromium firefox` | Exit 0; pinned browser binaries downloaded outside repository |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p0-gems/installed:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 PLAYWRIGHT_BROWSERS_PATH=/tmp/knowledge-sdk-dashboard-p2-browsers npm_config_cache=/tmp/knowledge-sdk-dashboard-p2-npm-cache npm --prefix optional/dashboard test > /tmp/knowledge-sdk-dashboard-p2-browser-matrix.log 2>&1` | Exit 0; 28/28 checks passed in 1.1m: login/search/logout, all deep links, keyboard/dialog focus, hostile HTML/Unicode, hidden records, independent errors/retry/late results, expiry, all widget states/evidence/date-only values, filter cancellation and failed logout across four browser/viewport projects |
| Playwright CLI visual inspection in isolated `knowledge-dashboard-p2` session | Inspected desktop login and Home at 1440x900, plus Home with real synthetic search data at 390x844; readable forms/tables, visible states and no page overflow/overlap. Screenshots in ignored `output/playwright/p2-*.png` |
| `gem build knowledge-sdk.gemspec` and `gem build knowledge-sdk-dashboard.gemspec` (second cwd `optional/dashboard`) | Exit 0 for both, version 17.0.0; existing homepage warning only |
| `gem install --local ... --install-dir /tmp/knowledge-sdk-dashboard-p2-install --ignore-dependencies --no-document` for each built gem | Exit 0; isolated install, no publishing/global installation |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p2-install:/tmp/knowledge-sdk-dashboard-p0-gems/installed:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 ruby /tmp/knowledge-sdk-dashboard-p2-installed-smoke.rb` (cwd `/tmp`) | Exit 0; installed CLI login/search/availability outside checkout, unchanged canonical bytes, Dataset absent, sanitized logs, all five hashed assets/imports present and correct; 41,597 uncompressed bytes including shell, below P0's 250 KiB asset target |
| Final scripted source/document inspection (`ruby -c`, `node --check`, JSON parsing, Markdown fences/local link existence and whitespace) | Exit 0; 5 Ruby files, 6 JS modules/config/tests, 2 JSON files, 6 Markdown files, 34 local links and 4 JSON API contract examples passed |
| `git diff --check`, complete tracked/untracked change review and `git status --short` | Exit 0; only intended P2 source/docs/tests are delivered; no generated gem, core lockfile, acceptance reports, runtime state or credentials included |

- Initial issues resolved: npm's default cache was blocked (used an approved
  temporary cache); macOS sandbox blocked browser Mach-port startup (browser checks
  rerun with approval outside sandbox); Chromium history setup initially returned
  to about:blank during a logout test (fixed the synthetic history setup, then all
  28 passed). Filter changes now terminate loading instead of leaving an aborted
  spinner state. No failing required functional or browser check remains.
- Limits: later Contacts/Capture/Activity/Finance/Health/automation capabilities,
  cursor-backed domain paging, clinical charts and ordinary refresh polling remain
  P3-P6. No chart library was needed in P2. Latest-Ruby execution, domain-integrated
  performance/security acceptance and release verification remain P7 gates. Browser
  coverage is the selected Chromium/Firefox matrix, not a claim about every engine.
- Only synthetic fixtures/local HTTP were used. No real private Vault, external
  integration, proposal, approval, canonical edit, publish, deploy or commit occurred.
  Generated acceptance reports, gems, lockfile/runtime/browser artifacts are kept
  out of the delivered change set; preserve the intended P2 source/docs/tests.
  The six tracked acceptance reports were restored from the initially clean HEAD;
  generated gems and core Gemfile.lock are under
  `/tmp/knowledge-sdk-dashboard-p2-verification/`. The development package-lock.json
  is intentionally delivered. The isolated visual browser and synthetic host were
  closed after inspection.
- Next session: **P3-a**, typed Contacts/Memory reads through the existing registrar.
  Reuse the P2 API/client/widget/drawer patterns, enforce visible-only ranking and
  traversal, inject read-only Dataset/Activity primitives, and keep exact approval
  and canonical write authority unchanged. Do not start P3 in this session.

Suggested next-session prompt:

```text
Implement Dashboard phase P3, starting with P3-a. Read AGENTS.md, the required root
docs, Dashboard contracts/progress/operator guide and nearest Graph/Intelligence/
Capture/Activity docs and tests. Preserve P2 source/docs/tests. Add the planned
typed Contacts, Capture and Activity read contracts with visible-only ranking,
bounded traversal, safe field/evidence projection and nonmigrating reader injection.
Use synthetic data only. Run required checks, update Progress with exact evidence
and stop at the P3 handoff; no next phase, commit, publish or deployment.
```

### 2026-10-25 — P3-a/P3-b Contacts, memory and bounded search

- Status after final review: **P3 complete**. Exit criteria and required checks
  passed; P4 remains not_started. No commit, publication or deployment performed.
- Starting revision: `31dc14f` (`DashBoard P1`). All uncommitted P2 source/docs/tests
  listed in the P2 handoff were present at session start and preserved. No unrelated
  changes were found. Required root/Dashboard and Graph/Intelligence/Capture/Activity
  docs, source and nearest tests were inspected before editing.
- Delivered seven typed read capabilities, version 1.0.0, through the ordinary
  SDK manifest/handler registrar: kg.contacts.list/get/top/relations,
  kg.captures.list/get and kg.activity.list. Each is synchronous, read_only,
  approval:none, low risk, schema-validated and invoked through opaque Gateway
  tokens with per-invocation policy. No broad analysis, conversation, proposal,
  approval, canonical-write, fetch or operational-control route was enabled.
- SDK files: new `lib/agent_platform/{read_views,memory_reads}.rb`, new
  `config/agent_platform/manifests/typed-reads.json`, default handler/bootstrap
  requires and Services activity-reader injection. Capture Search adds a typed
  literal-filter entry point without changing conversational search. Extraction
  adds `ProposalReader` and shared read-format methods; ProposalStore's existing
  writer/default behavior remains intact. Activity injects that narrow reader plus
  a nonmigrating Dataset source and cache:false; tests reject writer construction.
- Optional files: new cursors/domain_routes modules, App/Bridge/loader and availability
  manifest updates. Added fixed GET route mappings only. Cursors are random 32-byte
  session/filter/capability/version/last-key bindings with five-minute TTL,
  100/session and 1,000/process caps and logout/expiry cleanup. Before/after permitted
  dependency comparisons retry once within the Gateway deadline; visible source
  drift yields partial or cursor 409, never mixed page snapshots.
- Browser: Contacts ranking/date/profile/relationship reads; separate Capture and
  knowledge-change Activity lists with literal filters and half-open time windows;
  bounded paging; safe details/evidence; independent federated search results;
  graph/saved-resource metadata on Learning with progress unavailable. Shared-query
  changes cancel all dependent reads. Async drawer updates preserve keyboard focus,
  and closing a loading drawer cancels its pending detail reads. No browser payload
  persistence, HTML execution, external requests or fake domain data was added.
- Contracts: contact readiness checks parsed person semantics rather than folder
  detection. Interaction-v1 reuses recency/frequency 1.0.0 over the visible snapshot;
  strength reuses relationship_strength 1.0.0. Hidden structural endpoints are removed
  before features/traversal. No interactions means null/unknown, not zero importance.
  Contacts list/name-ID sorting, top score/ID ties, Capture score/time/ID and Activity
  time/ID keysets are deterministic. Traversal caps 100 nodes/200 edges/depth two.
- Privacy and coverage decisions: hidden/unresolved Capture links are removed before
  relevance scoring. Plain-text details are bounded at 10,000 characters, excerpts
  500, evidence 20; no attachment or bookmark URL destination is exposed/fetched.
  Activity omits redacted/unknown items and audits with hidden references before
  search/paging. It rebuilds summaries from permitted objects and SDK change types,
  omitting original actor/source/proposal/approval payloads. Visible authorized Dataset
  registration events are supported; historical row changes cannot prove their past
  privacy from present-day row state, so they remain omitted with an explicit
  dataset_row_history_not_projected warning. Denied/no-visible Dataset sources are
  not probed and return only dataset_activity_not_available; hidden-only Dataset
  creation cannot change visible Activity versions. Visible missing/outdated storage
  propagates safe reader warnings without creation/migration. activity:read is opt-in;
  P1's default grants remain unchanged. A 50,000-file/32 MiB scan budget bounds inputs.
- Docs/tests: API Contract, Architecture status, root/companion README, Operator Guide,
  owning Intelligence/Capture/Activity/Search docs and implementation/progress status
  updated. Added typed SDK and HTTP cursor/privacy/window tests, updated discovery
  expectations from 34 to 41 manifests, and extended the pinned browser matrix to
  40 checks (ten scenarios across Chromium/Firefox at 1440x900 and 390x844).

Verification (Ruby 2.6.10, Node 22.13.1; only synthetic fixtures/local HTTP):

| Exact command / check | Final result |
|---|---|
| `ruby -Ilib test/agent_platform/typed_reads_test.rb` | Exit 0; 7 runs, 89 assertions, 0 failures/errors/skips; ranking/formula, hidden-only versions, restricted Captures/private points, empty safe renditions, traversal bounds, row-history coverage and writer refusal |
| `bundle exec rake test > /tmp/knowledge-sdk-dashboard-p3-core-tests.log 2>&1` | Exit 0; 282 runs, 3,278 assertions, 0 failures/errors/skips; 151.190210s |
| `ruby acceptance/test_acceptance.rb > /tmp/knowledge-sdk-dashboard-p3-acceptance-tests.log 2>&1` | Exit 0; 4 runs, 8 assertions, 0 failures/errors/skips |
| `ruby acceptance/run_acceptance.rb --run-id run_01M5SNDGHYACTFJSP7B0V8M436 > /tmp/knowledge-sdk-dashboard-p3-acceptance.log 2>&1` | Exit 0; PASS: 7,724 base notes, 10 Dataview blocks, 2,000 stress operations; also passed earlier run_01M5SMNMZNNBSGZ95T2VQJBWFD |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p0-gems/installed:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 ruby -Ilib -Ioptional/dashboard/lib -e 'Dir["optional/dashboard/test/*_test.rb"].sort.each { \|f\| require File.expand_path(f) }' > /tmp/knowledge-sdk-dashboard-p3-companion-tests.log 2>&1` | Exit 0; 12 runs, 353 assertions, 0 failures/errors/skips; capability-version/source/filter/session cursor binding, TTL/revocation, DST defaults/windows, policy/object denials, nonmigration and existing HTTP safeguards |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p0-gems/installed:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 PLAYWRIGHT_BROWSERS_PATH=/tmp/knowledge-sdk-dashboard-p2-browsers npm_config_cache=/tmp/knowledge-sdk-dashboard-p2-npm-cache npm --prefix optional/dashboard test > /tmp/knowledge-sdk-dashboard-p3-browser-matrix.log 2>&1` | Exit 0; 40/40 passed in 2.0m; Playwright 1.56.1 Chromium/Firefox desktop/mobile matrix |
| Playwright CLI isolated `knowledge-dashboard-p3` visual session | Desktop Contacts at 1440x900, mobile Contacts/Memory at 390x844 inspected; literal hostile names, readable states/filters, scrollable bounded tables, no page overflow/overlap. Ignored screenshots output/playwright/p3-*.png; browser and synthetic host stopped |
| `gem build knowledge-sdk.gemspec` and `gem build knowledge-sdk-dashboard.gemspec` (second cwd optional/dashboard) | Exit 0 for both, version 17.0.0; existing homepage warning only |
| `gem install --local ... --install-dir /tmp/knowledge-sdk-dashboard-p3-install --ignore-dependencies --no-document` for both built gems | Exit 0; isolated local install. Core-only version/optional-component-absent checks passed from /tmp before adding the companion |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p3-install:/tmp/knowledge-sdk-dashboard-p0-gems/installed:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 ruby /tmp/knowledge-sdk-dashboard-p3-installed-smoke.rb` (cwd /tmp) | Exit 0; installed CLI auth/search/availability and all seven P3 routes; five correct hashed assets/imports, 58,848 uncompressed bytes including shell; core excludes optional code; canonical bytes unchanged, Dataset absent, logs sanitized |
| Final source/document validation and `git diff --check` | Exit 0; 21 Ruby files, 6 JS modules/config/tests, 4 JSON files, 11 Markdown files, 44 local links and 4 JSON API examples passed syntax/parse/fence/link/whitespace checks; complete tracked/untracked diff and final status reviewed |

- Resolved during verification: discovery tests now expect the seven additive
  manifests; Dataset source authorization ignores operational run IDs while checking
  actual entity references; a rapid four-source browser test waits for terminal
  responses before submitting the next four (the real host's four-request cap was
  correctly returning 429). macOS browser startup/known test-host termination needed
  sandbox approval. No security/concurrency limit was relaxed. Final review also
  bound cursors to capability version and separated empty privacy-filtered Capture
  renditions from canonical body validation. No failing required check remains.
- Limitations: Dataset historical row Activity is explicitly incomplete; missing
  permitted sources show warnings. activity:read/private/restricted grants remain
  opt-in. Unsupported/missing CRM metadata, interaction signals, personal occurrences,
  learning progress, calendar, Finance, laboratory and automation views are not
  fabricated. Bookmark destinations/attachment previews remain unexposed. Latest
  Ruby, full integrated domain/performance/security release checks remain P7 gates.
- Generated reports/gems/core Gemfile.lock are excluded from delivery. The six
  tracked acceptance reports are restored byte-for-byte from the session-start
  backups; generated copies/artifacts are under
  `/tmp/knowledge-sdk-dashboard-p3-verification/`. Keep the intentional P2 npm lockfile
  and all preserved P2 source/docs/tests. No real Vault, external integration,
  publish, deploy, commit or P4 implementation occurred.
- Next session: **P4-a**, typed Finance read contracts and safe visible scope selection.
  Reuse fixed routes, policy/token dispatch, cursor/source-version binding and shared
  widgets. Inject the nonmigrating Reader into KnowledgeFinance::Service; avoid its
  default writable Engine and the conversational/proposal path. Preserve complete
  owner replay before display pagination, exact decimals, native currencies and
  unavailable marks/basis/history. P4-b integrates the page after its SDK contracts.

Suggested next-session prompt:

```text
Implement Dashboard phase P4, starting with P4-a. Read AGENTS.md, required root and
Dashboard docs/progress plus Finance service/projection/permissions/schema docs and
tests. Preserve all uncommitted P2/P3 work. Add typed Finance scope/report/transaction
reads through the existing registrar and opaque Gateway dispatch, with explicit
visible owner/account scope, injected nonmigrating Reader, complete replay before
display pagination and exact decimal/currency semantics. Use synthetic data only.
Run required checks, update Progress with exact evidence, and stop at P4 handoff;
no P5, commit, publish, deployment or external price/news fetch.
```


### 2026-10-25 — P4-a/P4-b Finance reads and browser

- Status: **P4 complete**. P5 remains not_started. No commit, publish or deployment.
- Starting revision: `6106247` (`V18 + P3`); the working tree was clean. P2/P3
  implementations were already in this revision and were preserved. No checkout,
  reset or unrelated change was performed. Read AGENTS.md, required root docs,
  Dashboard contracts/plan/session guide/progress/dependency evaluation, Finance
  docs/schemas, Service/Projection/catalog/permissions and nearest tests first.
- SDK delivery: `lib/agent_platform/finance_reads.rb`, its loader/default registrar
  integration and six additive strict manifests in `finance-reads.json`:
  kg.finance.scopes/net_worth/positions/liabilities/transactions/pnl, version 1.0.0.
  All use ordinary policy-filtered discovery and opaque-token invocation, synchronous
  read_only execution, approval:none, low risk, and finance:read/dataset:read/graph:read.
  The existing conversational Finance capability and its permissions are unchanged.
- Read safety: inject the existing nonmigrating Reader via Services plus a visible
  SnapshotCatalog into KnowledgeFinance::Service. Authorize registrations, rows and
  referenced identities before computation. All restricted inclusion requires the
  existing Finance/Graph/Dataset restricted conjunction. Exclude contracts with
  hidden/missing owners, underlying/issuer/custodian/counterparty references.
  No writable Engine, proposal store or cache is constructed during typed reads.
- Accounting: one consistent SQLite read loads permitted history in 10,000-row
  source pages, under the existing replay ceiling. Service/Projection replay full
  owner history before account/instrument display filters or pagination, retaining
  cross-account transfers/FIFO lots. Invalid/incomplete history or replay bounds
  return unavailable. Missing storage/registration/schema cannot become zero balances;
  absent observation Datasets retain history with unavailable marks/FX. Decimal strings,
  units/multipliers, native currencies, null basis/marks/P&L, known subtotal and
  source mark/FX times retain the owning Finance semantics. No JavaScript accounting.
- Projection: strict field allow-lists omit identifiers/details/row metadata,
  arbitrary source strings/paths, free-form collateral/interest terms and approvals.
  Source Evidence references are bounded/opaque; no bytes are opened. Source versions
  depend on permitted calculation history and catalog terms. Scope collections cap
  at 1,000; transactions sort effective_at/sequence/event_id descending, positions
  account_id/asset_id/currency ascending. Full replay is never a display page.
- Companion: six fixed GET routes and client allow-list entries, 30s report deadlines,
  existing session/filter/capability-version/source-version cursor bindings and
  drift retry. Required owner is never inferred; unrelated/hidden/absent explicit
  scopes have uniform not-found behavior. HTTP defaults resolve from configured-zone
  today once, then apply inclusive UTC Finance accounting dates. Monthly P&L requires
  date-only endpoints because Service#monthly is date-scoped. Periods past explicit
  as_of are rejected. Net worth/debts remain clearly owner-wide; account/instrument
  filters apply to positions/transactions/P&L, including external-flow detail.
- Browser: explicit owner selection even with one owner, related account/instrument
  controls, date/reporting-currency/direction/period controls, exact tables and safe
  detail/source drawers, independent errors/retry, bounded pages and obsolete-read
  cancellation. Monthly bars are grouped by native currency with exact table labels;
  missing P&L has no bar. Three report reads then two respect the host's four-request
  admission cap. Mobile Finance tables retain every column, overriding the shared
  shell's third-column hiding rule. Default operator grants remain unchanged.
- Documentation: root/companion README, API Contract, Architecture, Implementation
  Plan, Operator Guide, owning Finance README and this ledger updated. No migration,
  external connector, live price/news, approval or write endpoint was added.

Verification (Ruby 2.6.10, Node 22.13.1, synthetic fixtures/local HTTP only):

| Exact command / check | Final result |
|---|---|
| `ruby -Ilib test/agent_platform/finance_reads_test.rb > /tmp/knowledge-sdk-p4-typed-delivered.log 2>&1` | Exit 0; 6 runs, 121 assertions, no failures/errors/skips; 14.951794s. Service parity, exact fractional FIFO/transfers/fees, loans, two owners/native currencies, missing basis/marks/FX, monthly windows, all restricted grants, hidden-only version stability, hidden counterparty references, replay ceiling and writer refusal |
| `bundle exec rake test > /tmp/knowledge-sdk-p4-core-delivered.log 2>&1` | Exit 0; 288 runs, 3,399 assertions, no failures/errors/skips; 165.646051s |
| `ruby acceptance/test_acceptance.rb > /tmp/knowledge-sdk-p4-acceptance-tests-delivered.log 2>&1` | Exit 0; 4 runs, 8 assertions, no failures/errors/skips |
| `ruby acceptance/run_acceptance.rb --run-id run_01M5TY6GBJK2S5D9H7T77RWKPN --report-root /tmp/knowledge-sdk-p4-acceptance-reports > /tmp/knowledge-sdk-p4-acceptance.log 2>&1` | Exit 0; PASS: 7,724 base notes, 10 Dataview blocks, 2,000 stress operations. Reports went directly to /tmp; tracked reports unchanged |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p0-gems/installed:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 ruby -Ilib -Ioptional/dashboard/lib -e 'Dir["optional/dashboard/test/*_test.rb"].sort.each { \|f\| require File.expand_path(f) }' > /tmp/knowledge-sdk-p4-companion-delivered.log 2>&1` | Exit 0; 13 runs, 389 assertions, no failures/errors/skips; 4.549899s. Fixed Finance routes, defaults/inclusive UTC bounds, scope, cursor drift/filter binding, denials, old storage nonmigration and preserved P1/P3 safeguards |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p0-gems/installed:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 PLAYWRIGHT_BROWSERS_PATH=/tmp/knowledge-sdk-dashboard-p2-browsers npm_config_cache=/tmp/knowledge-sdk-dashboard-p2-npm-cache npm --prefix optional/dashboard test > /tmp/knowledge-sdk-p4-browser-final.log 2>&1` | Exit 0; 44/44 passed in 2.5m, Chromium/Firefox at 1440x900 and 390x844. Preserved 40 P2/P3 checks plus Finance owner selection, exact values, missing FX, monthly charts, hostile text, no external requests and canonical/logical Dataset nonmutation |
| Same browser environment, `npm --prefix optional/dashboard test -- --grep 'Finance isolates' > /tmp/knowledge-sdk-p4-browser-isolation.log 2>&1` | Exit 0; four additional checks passed in 32.9s across all projects: independent failure, retry and cancellation after clearing owner; no late values displayed. Current suite contains 48 checks; 44 plus four were verified in these two runs |
| Playwright CLI `knowledge-dashboard-p4` isolated visual session | Inspected synthetic Finance at desktop/mobile, plus full report screenshots from the matrix. Readable controls/tables, separate native currency values and clear partial states, no page overflow/overlap. Screenshots ignored under output/playwright/p4-*.png; browser and synthetic host closed |
| `gem build knowledge-sdk.gemspec --output /tmp/knowledge-sdk-p4-core.gem` and `gem build knowledge-sdk-dashboard.gemspec --output /tmp/knowledge-sdk-p4-dashboard.gem` (second cwd optional/dashboard) | Exit 0; both version 18.0.0; existing homepage warning only. Rebuilt after final documentation |
| `gem install --local /tmp/knowledge-sdk-p4-core.gem --install-dir /tmp/knowledge-sdk-dashboard-p4-install --ignore-dependencies --no-document` and equivalent companion install | Exit 0; isolated temporary install; no global install or publication |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p4-install:/tmp/knowledge-sdk-dashboard-p0-gems/installed:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 ruby /tmp/knowledge-sdk-p4-installed-smoke.rb` (cwd /tmp) | Exit 0; installed CLI auth and all six Finance routes, exact quantity, core excludes optional code, five correctly hashed assets/imports totaling 72,110 uncompressed bytes (below 250 KiB), unchanged canonical notes/logical Dataset schemas and rows, sanitized logs |
| Final Ruby/JS syntax, JSON/manifest parsing, Markdown fences/local links, complete tracked/untracked review, `git diff --check` and `git status --short` | Exit 0; 11 Ruby files, four JS modules/tests, one JSON manifest, eight Markdown files and 41 local links validated; 47 manifests including all six typed Finance contracts loaded. Intended P4 source/docs/tests only. Generated lockfile moved to /tmp; no gems, runtime state, credentials or acceptance reports delivered |

- Resolved verification issues: schema unions now carry the manifest-required type;
  Dataset registration lookup uses dataset_slug; regression expectations recognize
  the six additive capabilities and policy-denied Finance availability. The client
  fixed allow-list now contains all six routes. Browser sandbox Mach-port startup
  was refused by macOS; approved runs outside the sandbox passed. Finance fixture
  verification compares logical schemas/rows rather than mutable SQLite lock/shared
  memory bytes. Test fixture sensitivity changes use parsed YAML serialization.
  The installed smoke resolves /tmp's physical path when checking gem activation.
  No failing required check remains; no security/concurrency boundary was relaxed.
- Limits: recorded policy-visible Finance history only; unsupported instruments,
  tax/household/business P&L, automatic accrual, evidence previews and live quotes/FX/news
  remain unavailable per the owning subsystem. Chart coordinates are approximate;
  exact strings/tables remain authoritative. Latest Ruby and integrated performance/
  release-scale/security gates remain P7; no new performance claim is made here.
- Preserve all uncommitted P4 paths: new Finance reads/manifest, loader/registrar,
  manifest discovery test, typed Finance tests, companion bridge/domain routes,
  API/app/styles, HTTP/browser tests and Finance fixture, README/owning Finance and
  Dashboard docs. Existing P2/P3 source and npm lockfile are retained. Generated gems,
  install/runtime/browser artifacts and core lockfile stay under /tmp or ignored output.
- Handoff: P4 ends here. P5-a laboratory read contracts are the next possible unit,
  requiring a separate user request. No P5 implementation or external fetching ran.

Suggested next-session prompt (only when P5 is authorized):

```text
Implement Dashboard P5, starting with P5-a. Read AGENTS.md, required root and
Dashboard contracts/progress plus Health/Dataset/schema/permissions docs and tests.
Preserve the uncommitted P4 source/docs/tests and all P2/P3 behavior. Add typed
subject-scoped laboratory reads with the nonmigrating Reader, original units,
reference intervals and nonnumeric results. Use synthetic data only. Run required
checks, update Progress with exact evidence and stop at P5 handoff; no P6, commit,
publish, deployment or external fetch.
```

### 2026-10-25 — P5-a/P5-b Laboratory reads and Medical browser

- Status: **P5 complete**. P6/P7 remain not_started. No commit, publication,
  deployment, external fetch, real Vault or external integration access occurred.
- Starting revision: `6106247` (`V18 + P3`). Preserved all 25 uncommitted P4 paths
  (source/docs/tests, including the untracked Finance manifest/reads/fixtures).
  A byte snapshot under `/tmp/knowledge-sdk-p5-baseline` supported incremental diff
  review; no checkout/reset occurred. P4-only Finance implementation/fixture/tests
  remain byte-identical. Existing P2/P3 behavior is covered by the browser matrix.
- Prerequisites: read AGENTS, README, root Architecture/ADRs, Dashboard contracts,
  plan/session guide/progress/dependency evaluation, Health/Dataset/template/schema
  and Gateway policy docs; inspected Reader, template/registry, permissions,
  typed Finance/memory patterns and nearest tests before implementation.
- P5-a delivery: `lib/agent_platform/health_reads.rb`, loader/default registrar,
  two strict version-1.0.0 manifests in `health-reads.json`, and typed tests/shared
  synthetic Health fixture. `kg.health.labs` and `kg.health.lab_series` require
  health:read/dataset:read/graph:read, use ordinary opaque-token Gateway dispatch,
  read_only effects, low risk and approval:none. No write/approval capability added.
- Scope/privacy: explicit Dataset owner or row subject metadata, active visible
  Person identities, explicit selection even for one subject, uniform absent/hidden
  and unrelated-subject refusal. Owned empty Datasets can supply scopes. Unowned
  ambiguous rows and conflicting row/owner metadata have explicit unavailable codes.
  Clinical restricted inclusion requires both graph:restricted and dataset:restricted
  for Datasets, rows and subjects; hidden referenced identities exclude the record.
  Authorization precedes groups/pages/versions. Hidden-only row changes retain
  source versions and cursor bindings. Opaque row Evidence references never open
  files; source URIs/filenames/spans, comments and approval/Intent payloads stay private.
- Read/storage compatibility: one injected nonmigrating Reader transaction; no graph
  Engine, Dataset Engine, ProposalStore, cache or lifecycle construction during reads.
  Exact trusted template identity/version/digest or the explicit legacy blood_tests
  layout is required. SDK-owned bounded layouts recognize canonical date/analyte,
  legacy observed_at/marker, optional TEXT subject/sensitivity/method and recorded
  REAL/INTEGER/TEXT values. Unknown columns/types/template versions are unsupported.
  The existing numeric write template and every import/approval/migration default
  remain unchanged; P5 does not provide qualitative import or storage repair.
- Clinical data: arbitrary analytes, original value/unit, date, panel, reference
  low/high/text and flag, specimen/laboratory/method are retained. TEXT values such
  as Negative, <5 and 123 stay text. No clinical numeric coercion, unit conversion,
  inferred ranges, diagnoses or treatment. Series group by subject/analyte/unit/
  method/specimen/laboratory; unknown metadata stays separate. Output is raw with
  aggregation:none and explicit partial group/point bounds (10/1,000). Combined
  source scans over 100,000 rows or 50 registrations are unavailable. Scope cap is
  1,000 subjects; strings over 1,000 characters are refused rather than truncated.
- HTTP/browser: two fixed GET routes/client allow-list entries, explicit typed
  filters, inclusive date-only windows (30 dates through configured-zone today by
  default, endpoints <=366 days apart), unchanged date-only clinical dates across
  DST, 5s list/30s series deadlines and existing session/query/version cursor/drift
  handling. Medical offers subject selection, original tables, a timeline of the
  current page, separate raw numeric-point plots with per-row recorded intervals,
  text-only table groups and safe observation/source drawers. Series filters are
  visibly separate from history filters. Independent errors/retry, bounded pages,
  navigation/filter/logout cancellation and private DOM clearing are retained.
- Documentation: owning [Typed laboratory reads](../Health%20Plugin/Laboratory%20Reads.md),
  Health README, Gateway Policy Guide, root/companion README and Dashboard
  API/Architecture/Operator Guide/Implementation Plan/Progress updated. Existing
  operator permission enum already reserved health:read; default grants unchanged.
  No new dependency, schema migration, upload/OCR or P6 inventory/refresh behavior.

Verification (Ruby 2.6.10, Node 22.13.1; synthetic data and local loopback only):

| Exact command / check | Final result |
|---|---|
| `ruby -Ilib test/agent_platform/health_reads_test.rb > /tmp/knowledge-sdk-p5-typed.log 2>&1` | Exit 0; 6 runs, 120 assertions, no failures/errors/skips; 14.634225s. Subjects, restricted conjunction, hidden references/versions, original numeric/text results/intervals, grouping, paging, legacy dates, unsupported schemas, unknown/conflicting scopes, empty owners, source/output bounds and writer refusal |
| `bundle exec rake test > /tmp/knowledge-sdk-p5-core-final.log 2>&1` | Exit 0; 294 runs, 3,519 assertions, no failures/errors/skips; 180.330638s |
| `ruby acceptance/test_acceptance.rb > /tmp/knowledge-sdk-p5-acceptance-tests.log 2>&1` | Exit 0; 4 runs, 8 assertions, no failures/errors/skips |
| `ruby acceptance/run_acceptance.rb --run-id run_01M5V0P5A00000000000000000 --report-root /tmp/knowledge-sdk-p5-acceptance-reports > /tmp/knowledge-sdk-p5-acceptance.log 2>&1` | Exit 0; PASS: 7,724 base notes, 10 Dataview blocks, 2,000 stress operations. Reports directly under /tmp; tracked reports unchanged |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p0-gems/installed:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 ruby -Ilib -Ioptional/dashboard/lib -e 'Dir["optional/dashboard/test/*_test.rb"].sort.each { \|f\| require File.expand_path(f) }' > /tmp/knowledge-sdk-p5-companion.log 2>&1` | Exit 0; 14 runs, 420 assertions, no failures/errors/skips; 6.962766s. Includes preserved P1/P3/P4 security/routes plus laboratory dates/scopes/cursors/drift, denied availability and old-storage nonmigration |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p0-gems/installed:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 PLAYWRIGHT_BROWSERS_PATH=/tmp/knowledge-sdk-dashboard-p2-browsers npm_config_cache=/tmp/knowledge-sdk-dashboard-p2-npm-cache npm --prefix optional/dashboard test > /tmp/knowledge-sdk-p5-browser-full.log 2>&1` | Exit 0; 56/56 passed in 3.6m, Chromium/Firefox at 1440x900 and 390x844. Preserved 48 P2/P3/P4 checks plus eight Medical checks. Canonical/runtime bytes and logical Dataset schemas/rows unchanged; no external requests |
| Same browser environment, `npm --prefix optional/dashboard test -- --grep Medical > /tmp/knowledge-sdk-p5-browser-focused.log 2>&1` | Exit 0; 8/8 passed in 53.2s after final table styling and screenshot additions; independent failure/retry and obsolete-subject cancellation included |
| Visual inspection of ignored `output/playwright/p5-*.png` and viewport screenshots, plus a temporary mobile table crop | Desktop/mobile controls, literal hostile strings, original row values, separate series, readable horizontally scrolling tables with every column retained, and unavailable diagnoses inspected; no page overflow/overlap |
| `gem build knowledge-sdk.gemspec --output /tmp/knowledge-sdk-p5-core.gem` and `gem build knowledge-sdk-dashboard.gemspec --output /tmp/knowledge-sdk-p5-dashboard.gem` (second cwd optional/dashboard) | Exit 0; both 18.0.0, existing homepage warning only; rebuilt after final docs |
| `gem install --local /tmp/knowledge-sdk-p5-core.gem --install-dir /tmp/knowledge-sdk-dashboard-p5-install --ignore-dependencies --no-document` and corresponding companion install | Exit 0; isolated temporary installation only |
| `GEM_PATH=/tmp/knowledge-sdk-dashboard-p5-install:/tmp/knowledge-sdk-dashboard-p0-gems/installed:/Library/Ruby/Gems/2.6.0:/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0 ruby /tmp/knowledge-sdk-p5-installed-smoke.rb` (cwd /tmp) | Exit 0; installed 18.0.0 CLI authentication, all six Finance and both laboratory routes, subject isolation, original text values and separate series; unchanged canonical notes/logical Dataset schemas and rows; sanitized logs; five hashed assets totaling 85,074 bytes (<250 KiB) |
| Core-only gem path, `ruby /tmp/knowledge-sdk-dashboard-p5-install/bin/kg version` (cwd /tmp) | Exit 0; ordinary core CLI reports 18.0.0 without optional web dependencies on the gem path |
| Changed-file Ruby/JS syntax, JSON/manifests, Markdown fences/local links, new-file whitespace, complete P4-to-P5 and tracked/untracked diff review, `git diff --check`, `git status --short` | Exit 0; 15 Ruby files, four JS modules/tests, two JSON manifests, 11 Markdown files/47 local links, 11 new-file whitespace checks. All 49 manifests load; P4-only Finance files byte-identical; intended P4/P5 paths only after generated lockfile cleanup |

- Verification corrections: Ruby Column#to_h uses symbol keys; fixture/schema
  projection was corrected accordingly. Synthetic provenance is a positional third
  argument, so fixture Evidence was corrected. Default-discovery expectations now
  exclude opt-in Health capabilities. An initially malformed harness run ID was
  rejected before work and replaced with the valid 26-character ID above. Initial
  browser launch was blocked by macOS sandbox; approved runs outside it passed.
  A source-ceiling test intermittently reached the unchanged 5s list deadline under
  concurrent harness load; it now verifies the same shared scan via the existing
  30s series contract. No production timeout or safety bound was relaxed.
- Limits: recorded, explicitly scoped compatible laboratory storage only. No
  cross-method/unit/specimen conversion or clinical inference; text-stored numeric
  strings remain unplotted. Broad release-scale performance/latest-Ruby/security
  gates remain P7 and are not claimed complete by these tests. Raw output bounds
  require narrower filters; there is no silent clinical downsampling.
- Artifacts: generated gems/install files/logs/reports and the generated Bundler
  lockfile remain under /tmp; browser screenshots/traces are ignored output.
  No credentials, real paths/runtime data, migration backup or generated report is
  part of the delivered changes. All preexisting P4 changes remain uncommitted.
- **P5 handoff:** laboratory reads and Medical UI end here. The next possible unit
  is P6-a (sanitized operational reads/time semantics) only after a separate user
  request. No P6 work, commit, publication, deployment or external fetching ran.

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
