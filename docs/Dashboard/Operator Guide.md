# Optional Dashboard host — P1

P1 implements the local authenticated read API, not the P2 browser application.
`/` serves a packaged informational page. Search, authentication, availability and
owned-job metadata are implemented; Contacts, Finance, Health, Activity, overview
and operational inventory routes arrive in later phases. Unsupported routes return
404 and availability labels those features unsupported. There are no editing,
approval, submission, fetch, plugin-install or schedule-control endpoints.

## Install the optional component from source

The ordinary `knowledge-sdk` gem and `kg` commands do not need web gems. The
companion component is version-aligned with the core. Until separately published,
build/install it from this checkout (choose a writable gem installation location):

```sh
gem build knowledge-sdk.gemspec
gem install ./knowledge-sdk-17.0.0.gem
cd optional/dashboard
gem build knowledge-sdk-dashboard.gemspec
gem install ./knowledge-sdk-dashboard-17.0.0.gem
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

The P2 login interface is not present yet. A same-origin API client follows:

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
4. POST an empty JSON object to `/api/v1/session/logout` with cookie, Origin and the
   current CSRF token. Discard private client data immediately on logout or 401.

Sessions expire after 30 minutes idle or eight hours total. Polls marked
`X-Dashboard-Poll: 1` do not extend idle time. Authentication failures, input bounds,
Host/Origin/CSRF failures and throttling use safe JSON errors. All responses have
no-store, no-referrer and a restrictive CSP. Imported strings remain JSON text;
the informational page renders no Vault content. No external assets/models or
telemetry services are used. HTTP cookies are not marked Secure on this loopback
HTTP host; remote/TLS deployment is outside this release.

The Gateway holds invocation tokens server-side and enforces read_only policy plus
the dashboard identity allow-list on every invocation. Stale tokens rediscover once.
Each browser session has a different agent identity. Up to four data computations,
20 authenticated/20 pre-login sessions, bounded request rates, 1 MiB responses and
1,000 expiring telemetry records are allowed. Logs contain route templates, random
request IDs, status and duration, never filters, secrets or payloads.

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
Latest-stable Ruby, full browser layouts and measured dashboard performance remain
P7 release gates; see [Progress](Progress.md) for exact evidence and limitations.

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
