# Optional Dashboard — P5

P5 adds subject-scoped laboratory history and trends to typed Finance reports,
Contacts, Captures and Knowledge Activity in the
local authenticated read API. Open the printed loopback URL, enter the configured secret and browse Home, Search and all
six category pages. Exact identity search and availability are connected to real
SDK reads; Contacts ranking/profiles/relations, Capture lists/details and independent
search sources are connected. Knowledge Activity requires the opt-in activity:read
grant plus each included source permission. Finance requires all of `finance:read`,
`dataset:read` and `graph:read`; default grants are unchanged. Health requires all of `health:read`, `dataset:read` and `graph:read`. Overview and
operational inventory APIs arrive in later phases. Their pages explain what is
unavailable; unsupported API routes return 404. There are no editing,
approval, submission, fetch, plugin-install or schedule-control endpoints.

## Install the optional component from source

The ordinary `knowledge-sdk` gem and `kg` commands do not need web gems. The
companion component is version-aligned with the core. Until separately published,
build/install it from this checkout (choose a writable gem installation location):

```sh
gem build knowledge-sdk.gemspec
gem install ./knowledge-sdk-18.0.0.gem
cd optional/dashboard
gem build knowledge-sdk-dashboard.gemspec
gem install ./knowledge-sdk-dashboard-18.0.0.gem
```

The companion installs exact Rack 3.2.7, rackup 2.3.1, WEBrick 1.9.2, TZInfo 2.0.6,
concurrent-ruby 1.3.8 and tzinfo-data 1.2026.5. Ruby 2.6 is retained. No Node or
native web-server extension is needed. Merely installing it does not attach a
Vault, install a profile or initialize Dataset storage. Without the component,
`kg dashboard` exits 2 with an optional-install instruction; ordinary commands work.

## Start and stop

Provision a high-entropy base64url secret file outside the selected Vault, owned by
the operator with mode 0600. For example, create it in a new private directory:

```sh
mkdir -m 700 /tmp/kg-dashboard-operator
ruby -rsecurerandom -e 'File.open("/tmp/kg-dashboard-operator/secret", File::WRONLY | File::CREAT | File::EXCL, 0600) { |f| f.puts(SecureRandom.urlsafe_base64(32)) }'
kg dashboard serve --vault /path/to/an/explicit/vault --timezone Europe/Berlin --secret-file /tmp/kg-dashboard-operator/secret
```

The example paths are placeholders for an operator's explicit selection. The host
never discovers a real Vault on its own. `--vault`, `--timezone` and `--secret-file`
are required. Secret files must be regular, owner-only and outside the Vault;
symlinks and permissive files are refused. No secret is printed in the startup URL.
Remove the temporary operator secret when it is no longer needed; recreate/restart
to rotate it. Production operator secrets can live in another private external
directory. Secret entropy is the operator's responsibility.

The server prints `http://127.0.0.1:8765`. Use exactly that host/port. `localhost`,
LAN addresses, proxies and forwarded headers are deliberately rejected. `--port`
accepts 1024-65535; there is no remote bind option. Stop with Ctrl-C or SIGTERM.
Sessions, jobs, read metadata and telemetry are process memory and disappear on
restart. This host does not run or stop a scheduler/worker.

Existing `--config` / `KG_CONFIG` and `--dataset-db` / `KG_DATASET_DB` controls apply.
They may appear before `dashboard` or after `serve` as CLI options. Dataset path
resolution is frozen at startup: explicit/environment override, external
configuration, then `.knowledge/datasets.sqlite3` under the explicit Vault. Relative
overrides are Vault-relative. There is no request-supplied path or Vault switch.

Optional `--settings FILE` reads an owner-only external JSON object:

```json
{"version":1,"display_label":"Synthetic research","permissions":["graph:read","capture:read","intelligence:read"]}
```

Unknown keys, wildcard/unknown permission strings and invalid values fail startup.
The default grants match the example. Private/restricted grants require explicit
operator settings. Only the fixed implemented read-capability allow-list can run,
even if settings name other reserved domain-read grants. Schedule settings are
reserved for P6 and explicitly rejected in P1. Configuration/policy changes require
restart and therefore invalidate all sessions and jobs.

## Authenticate and read

Use the browser login form for ordinary browsing. It clears the secret field on
submission and retains only session metadata in memory. Search text/filters never
enter page URLs or browser storage. A same-origin API client can also follow:

1. GET `/api/v1/session`, retain the HttpOnly/SameSite=Strict cookie and returned
   `csrf_token`. The unauthenticated response contains no Vault context.
2. POST JSON `{"secret":"..."}` to `/api/v1/session/login`, sending that cookie,
   `Origin: http://127.0.0.1:8765` and `X-CSRF-Token`. Use the rotated response cookie
   and CSRF token afterwards. Keep secrets out of URLs, shell history and logs.
3. GET `/api/v1/search?q=Ada&limit=25` or `/api/v1/dashboard/availability` with the
   authenticated cookie. Search uses the SDK's existing deterministic exact identity
   matching, not substring/full-text or natural-language analysis. Results are ordered
   by immutable ID, exclude restricted entities without permission, and exclude
   email/phone/external-ID-only matches without `graph:private`. The bounded P1
   search has no cursor; a reached limit returns partial with a limit warning.
   The browser's Previous/Next controls stay disabled for this bounded read; refine
   the query or choose a limit of 25, 50 or 100. No missing pages are fabricated.
4. POST an empty JSON object to `/api/v1/session/logout` with cookie, Origin and the
   current CSRF token. Discard private client data immediately on logout or 401.

Sessions expire after 30 minutes idle or eight hours total. Polls marked
`X-Dashboard-Poll: 1` do not extend idle time. Authentication failures, input bounds,
Host/Origin/CSRF failures and throttling use safe JSON errors. All responses have
no-store, no-referrer and a restrictive CSP. Imported strings remain JSON text;
the interface renders permitted imported strings as literal text. No external assets/models or
telemetry services are used. HTTP cookies are not marked Secure on this loopback
HTTP host; remote/TLS deployment is outside this release.

The Gateway holds invocation tokens server-side and enforces read_only policy plus
the dashboard identity allow-list on every invocation. Stale tokens rediscover once.
Each browser session has a different agent identity. Up to four data computations,
20 authenticated/20 pre-login sessions, bounded request rates, 1 MiB responses and
1,000 expiring telemetry records are allowed. Logs contain route templates, random
request IDs, status and duration, never filters, secrets or payloads.

## Check Contacts, Memory and Search

Contacts lists permitted people by name/ID and supports literal name/alias filters.
Top recorded contacts uses the documented interaction-v1 formula; its reasons,
recorded interaction count and latest substantive date are visible. Missing signals
remain unknown. The date control applies to ranking and relations. Open a contact
for permitted fields and a depth-two relationship list (100 nodes/200 edges max).
Email/phone require an explicit graph:private grant.

Memory presents Capture records and knowledge-change history separately. Capture
filters select kind/lifecycle and optional offset-bearing from/to times; words in
the search box do not select lifecycle or time filters. Details show a plain-text
rendition, a truncation notice where necessary and permitted source references.
Capture creation is recorded time, not a personal event. No attachments or bookmark
URLs are fetched. Learning shows existing identities and saved resource metadata;
learning progress and personal occurrences remain unavailable.

To enable Knowledge Activity, include activity:read in your external settings
permissions along with the desired source grants, then restart. For example:

```json
{"version":1,"permissions":["graph:read","capture:read","intelligence:read","activity:read"]}
```

Activity's default window is 30 configured-zone calendar days through today.
Explicit from/to filters require both endpoints with offsets, use an exclusive end
and allow at most 366 calendar days. DST days retain their actual 23/25-hour length.
The list omits hidden/redacted and unknown-provenance records. Dataset registration
history additionally needs dataset:read and visible Dataset metadata. Historical
Dataset row changes remain omitted with a coverage warning because current rows
cannot establish their historical privacy. Graph/Capture history remains usable
when a Dataset source is denied, missing or requires an explicit administrative
upgrade. No storage is created or upgraded by browsing.

Search presents graph identity, Contact, Capture and Activity results independently;
matching records may appear in multiple sources and counts are never added together.
Contacts/Captures/Activity page in stable order, with at most five pages per UI
query. Refine filters after that bound. Cursors expire after five minutes and belong
to one session/query/source version. A visible source edit asks you to restart the
query; hidden-only edits do not change visible versions or page bindings.

## Storage, errors and operational limits

Browsing never constructs a graph Engine or proposal store, creates/migrates a
Dataset database, installs plugins or initializes `.knowledge` runtime directories.
`StructuredDataset::Reader` requires existing engine-schema version 3. Missing,
older, newer, malformed or unreadable storage produces safe availability codes;
recover through the existing explicit administrative/approved lifecycle workflow,
then retry/restart as appropriate. Browsing cannot repair storage. Existing SQLite
WAL shared-memory coordination is the sole allowed storage-read side effect; it
does not create a missing main DB or parent directory. P1 search/availability do not
need to open Dataset storage at all; later typed Dataset widgets use that facade.

P1 admits synchronous read contracts only and creates no asynchronous user jobs.
`GET /api/v1/jobs/:id` is reserved owned metadata infrastructure: cross-session,
unknown, expired and revoked IDs all return 404. Raw Gateway results are never
serialized. The bounded manager admits at most 20 jobs/agent and 100/process, with
a 10-minute terminal TTL and logout cleanup. A later asynchronous route must add
its typed result adapter before enabling 202 tickets. Restart loses jobs; repeat
the read. Durable automation jobs are a separate future inventory, not these jobs.

There is no report cache, SSE, persistent browser store, multi-Vault process or
cross-widget atomicity promise. Search compares successive permitted results under
a five-second budget, retries visible drift once and returns partial if unstable.
Opaque result versions change with visible results/filters, not hidden-only edits.
Search and availability fail independently. The UI distinguishes loading, empty,
partial, unavailable, stale and error states, preserves warnings/coverage/source
timestamps, and offers retry where appropriate. Record/source drawers show only
supplied permitted fields and references, with no arbitrary attachment preview.
Dates without a time remain dates. Navigation, filter changes and logout abort
obsolete requests and ignore late results. Private DOM is cleared immediately on
logout, including failed logout; use the retry control to confirm server revocation.

Static source files are package-owned. The server generates a fixed allow-list
with content-hashed JS/CSS/SVG URLs in memory at startup. Restart after an upgrade
and reload open tabs. No assets, configuration or scripts are loaded from a Vault.
Session data responses include `X-Dashboard-Session-Expires-At`, allowing the browser
to revalidate expiry without extending idle time through polling. No ordinary
widget refresh polling is implemented before P6.

Chromium/Firefox desktop/mobile browser checks cover the shell, Contacts/Memory
and Finance pages. Latest-stable Ruby,
integrated domain coverage and measured dashboard performance remain P7 release
gates; see [Progress](Progress.md) for exact evidence and limitations.

## Developer verification

Core checks remain `bundle exec rake test`, `ruby acceptance/test_acceptance.rb` and
the synthetic full harness for cross-subsystem work. With the optional gems on the
Ruby gem path, run the separate companion suite from the checkout root:

```sh
ruby -Ilib -Ioptional/dashboard/lib -e 'Dir["optional/dashboard/test/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
```

It uses synthetic temporary Vaults/configuration and a real loopback listener as
well as Rack requests. It does not access a private Vault or external integration.
Build both gems and verify a core-only plus companion installed environment outside
the source checkout. Never deliver generated gems, acceptance Vaults or credentials.

For browser verification, from `optional/dashboard` run `npm ci`,
`npx playwright install chromium firefox`, then `npm test`. This is development-only
tooling pinned by package-lock.json. Tests start their own synthetic Ruby host;
they never select an attached Vault. Set GEM_PATH to the optional dependencies if
using an isolated gem install. Browser traces/screenshots are ignored under
`output/playwright/`; they must not be committed.

## Finance reads

Install the Finance plugin explicitly using its normal SDK workflow before browsing.
Enable `finance:read`, `dataset:read`, `graph:read` in the owner-only operator settings.
Select an owner in Finance even when only one is available, then load the reports.
Account and instrument filters apply to positions, transactions and investment P&L;
net worth and debts remain visibly owner-wide. Net worth defaults to EUR reporting,
while P&L retains separate native currencies. Reporting currency never changes an
account's native currency. Missing FX, marks and basis remain unknown/null.

The page provides exact decimal tables, bounded transaction/position pages, safe
source references and optional monthly P&L bars. Bar lengths are approximate; the
exact table is authoritative. Dates use inclusive UTC accounting boundaries, even
when the display timezone has a daylight-saving transition. Transactions default
to 30 dates ending today; P&L defaults to the current month. Explicit periods are
at most 366 calendar days apart; monthly reports require date-only endpoints.

Every report replays complete permitted owner history before account filters and
pagination. Browsing uses the configured nonmigrating Reader, never Finance's
writable default engine. Missing storage/history, incompatible schemas, incomplete
transfers/reversals or the existing replay ceiling produce unavailable states.
Missing observation Datasets mean unavailable marks/FX, with usable recorded history
retained. Restricted inclusion requires all three of `finance:restricted`,
`graph:restricted` and `dataset:restricted`; every referenced identity must also be
visible. Account identifiers, arbitrary metadata, local source paths and approval
payloads are absent. No evidence preview, live quotes, FX/news fetching or trades
are exposed. Existing Finance instrument/accounting limitations still apply.

## Laboratory history and trends

Enable `health:read`, `dataset:read` and `graph:read` in the external operator settings
and restart. Choose a recorded laboratory subject explicitly, then load history.
Dataset ownership or explicit row subject metadata must establish that scope.
Unowned ambiguous tables remain unavailable; browsing cannot assign a patient or
repair/provision storage. Restricted clinical rows, Datasets and subjects require
both `graph:restricted` and `dataset:restricted`. Default grants are unchanged.

Medical retains the original result table, report intervals/flags and a timeline
of the current page. Enter an exact recorded analyte for separate raw-point charts.
Units, methods, specimens and laboratories remain separate, including unknown
metadata. Series-only filters are labeled. Date filters are inclusive dates,
defaulting to the last 30 dates through configured-zone today, and allow at most
366 days between endpoints. Dates without a time stay dates across DST changes.
Qualitative TEXT results remain text even when they look numeric; they have no
plotted point. Each chart has its original table below it. Source references are
opaque metadata and cannot open Evidence or local attachments.

The browser pages history up to five pages per query; refine filters afterwards.
Series responses explicitly mark raw bounds (ten groups, 1,000 points per group).
No clinical downsampling or inferred ranges are supplied. Diagnosis, treatment,
upload/OCR and clinical editing remain unavailable. See [Typed laboratory reads](../Health%20Plugin/Laboratory%20Reads.md)
for exact compatible storage layouts and source limits. Existing write templates
and conversational import behavior are unchanged.
