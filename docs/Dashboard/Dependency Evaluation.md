# P0 dependency and read-side-effect evaluation

Evaluated 2026-10-25 at `324aed9`, using synthetic temporary files only. These are
design selections for the optional component, not changes to SDK dependencies.
See [Architecture](Architecture.md) and [API Contract](API%20Contract.md).

## Selected dependency set

RubyGems version metadata and downloaded gem specifications were inspected for
these exact releases. Optional runtime pins:

| Package | Selected version | Declared required Ruby | Role |
|---|---|---|---|
| rack | 3.2.7 | >=2.4.0 | Rack protocol and request utilities |
| rackup | 2.3.1 | >=2.5 | Existing Rack-to-WEBrick adapter |
| webrick | 1.9.2 | >=2.4.0 | Pure Ruby loopback HTTP server |
| tzinfo | 2.0.6 | >=1.9.3 | IANA conversions without global TZ changes |
| concurrent-ruby | 1.3.8 | >=2.3 | Pinned TZInfo dependency |
| tzinfo-data | 1.2026.5 | >=1.8.7 | Reproducible Ruby timezone data, IANA 2026e |

Rackup requires Rack >=3. TZInfo requires concurrent-ruby ~>1.0; tzinfo-data
requires TZInfo >=1.0.0. Exact pins above satisfy those constraints. No native
extension, rack-session, rack-protection, frontend framework or chart gem is needed.
Dependencies retain their upstream licenses; include license notices when packaging
assets/component. No dependency files or lockfiles change in P0.

Evaluated alternatives: Rack 2.2.24 (>=2.3.0) is unnecessary because Rack 3.2.7
loads and passes MockRequest/Lint on Ruby 2.6.10. Puma 6.6.1 (>=2.4) depends on
nio4r ~>2.0; nio4r 2.7.5 declares >=2.6. Both native extensions failed to build on
this machine with `fatal error: 'ruby/config.h' file not found`. This is a local
system-Ruby development-header failure, not proof of incompatible Ruby syntax.
Puma 8.0.2, observed latest, declares >=3.0 and cannot be the Ruby 2.6 default.
Choose WEBrick with the explicit loopback/concurrency/request limits in Architecture;
do not silently fall back to another server at runtime. Future Puma support requires
its own native build/runtime checks and a recorded dependency decision.

Sources (public package metadata only; no external user integrations accessed):

- [RubyGems version API](https://guides.rubygems.org/rubygems-org-api/#gem-version-methods):
  `/api/v1/versions/NAME.json` and `/api/v2/rubygems/NAME/versions/VERSION.json` on rubygems.org.
- [Rack 3.2.7](https://rubygems.org/gems/rack/versions/3.2.7),
  [rackup 2.3.1](https://rubygems.org/gems/rackup/versions/2.3.1),
  [WEBrick 1.9.2](https://rubygems.org/gems/webrick/versions/1.9.2).
- [Puma 6.6.1](https://rubygems.org/gems/puma/versions/6.6.1),
  [nio4r 2.7.5](https://rubygems.org/gems/nio4r/versions/2.7.5),
  [Puma 8.0.2](https://rubygems.org/gems/puma/versions/8.0.2).
- [TZInfo](https://rubygems.org/gems/tzinfo/versions/2.0.6),
  [timezone data](https://rubygems.org/gems/tzinfo-data/versions/1.2026.5),
  [concurrent-ruby](https://rubygems.org/gems/concurrent-ruby/versions/1.3.8).
- [Playwright 1.56.1 npm metadata](https://registry.npmjs.org/@playwright/test/1.56.1):
  requires Node >=18; choose local Node 22.13.1 for P2 development-only tooling.
- [Ruby releases](https://www.ruby-lang.org/en/downloads/releases/): stable 4.0.9
  observed; latest-stable runtime check is still required at implementation/release.

## Compatibility evidence and remaining gates

| Check | P0 result | Later gate |
|---|---|---|
| Ruby minimum | System Ruby 2.6.10p210, arm64 macOS; exact selected gems install/load; Rack Lint/MockRequest and WEBrick adapter load | P1 actual authenticated host integration |
| TZInfo data | Force Ruby datasource; Europe/Berlin day lengths 23h/25h, Etc/UTC 24h | P5/P6 filters/cron DST behavior |
| SQLite | Existing sqlite3 1.3.13, SQLite 3.51.0; READONLY open works, SQL mutation refused, absent parent stays absent | P1 facade, old schema, WAL, override and concurrency regressions |
| Current Ruby | Ruby 4.0.9 is not installed; declared gem requirements admit it but that is not execution evidence | P1/P7 clean installation, suite and web smoke on latest stable; update version if a later stable exists |
| Browser | Node available; Playwright metadata checked only | P2 install locked tooling, browser download and real visual/keyboard/XSS QA |
| Native server | Puma/nio4r native build failed (missing system headers) | Resolved by selected pure Ruby server; no Puma release claim |
| Package | No optional package exists in P0 | P1 creates/builds it; P7 installed core-only + companion smoke outside checkout |
| Security/maintenance | Exact public releases inspected; no maintained-runtime or vulnerability-free guarantee inferred from version metadata | Recheck upstream advisories, dependency pins and supported Ruby matrix at P1/P7; record any blocker |

Ruby 2.6 is an existing SDK compatibility obligation despite upstream EOL. P0 does
not change that policy. Missing latest-Ruby/browser/product-host evidence is a
future release gate, not a claim that the product already works there. There is
no unresolved P0 dependency choice. Latency budgets are defined in Architecture;
no dashboard performance numbers were measured because no feature exists yet.

## Reproducible minimum-Ruby dependency probe

Download the exact six gems above from `https://rubygems.org/downloads/NAME-VERSION.gem`
into a temporary directory. Use `gem install --local GEM_FILES --install-dir
TEMP/installed --ignore-dependencies --no-document` for the complete pinned set;
this avoids altering global gems or repository dependency files. Alternatively
resolve an isolated temporary Gemfile with the same six exact pins. Do not install
or start anything against a real Vault. Run the following Ruby block with
`GEM_HOME=TEMP/installed GEM_PATH=TEMP/installed ruby TEMP/dependency_probe.rb`:

```ruby
require "rack"
require "rack/mock"
require "rack/lint"
require "rackup/handler/webrick"
require "tzinfo"
require "tzinfo/data"
require "date"

expected = {
  "rack" => "3.2.7", "rackup" => "2.3.1", "webrick" => "1.9.2",
  "tzinfo" => "2.0.6", "concurrent-ruby" => "1.3.8", "tzinfo-data" => "1.2026.5"
}
expected.each do |name, version|
  actual = Gem.loaded_specs.fetch(name).version.to_s
  raise "unexpected #{name} version" unless actual == version
end
app = Rack::Lint.new(lambda do |_environment|
  [200, { "content-type" => "text/plain" }, ["synthetic"]]
end)
response = Rack::MockRequest.new(app).get("/")
raise "Rack probe failed" unless response.status == 200 && response.body == "synthetic"
raise "adapter missing" unless Rackup::Handler::WEBrick::Server < WEBrick::HTTPServer
TZInfo::DataSource.set(:ruby)
[["Europe/Berlin", "2026-03-29", 23],
 ["Europe/Berlin", "2026-10-25", 25],
 ["Etc/UTC", "2026-10-25", 24]].each do |zone_name, date_text, hours|
  zone = TZInfo::Timezone.get(zone_name)
  date = Date.iso8601(date_text)
  following = date + 1
  start = zone.local_to_utc(Time.utc(date.year, date.month, date.day))
  finish = zone.local_to_utc(Time.utc(following.year, following.month, following.day))
  raise "DST probe failed" unless finish - start == hours * 3600
end
puts "6 pinned gems loaded; Rack mock/lint and WEBrick adapter passed; DST 23/25/24h passed"
```

The probe loads the adapter but opens no HTTP listener. It does not validate host
security, sessions, product routes, or browser behavior. P0's separate SQLite probe
created a synthetic temporary table using the installed driver, reopened it with
`SQLite3::Constants::Open::READONLY`, verified its supplied text, verified INSERT
raises ReadOnlyException, and verified opening a missing nested path raises
CantOpenException without creating its parent. This validates driver feasibility;
it is not a substitute for P1 nonmutation tests of the proposed SDK reader.

## Inspected subsystem evidence

- `bootstrap.rb`, `gateway.rb`, `policy.rb`, `services.rb`, `handlers.rb`,
  `adapters/rest.rb`, `jobs.rb`, `security.rb` under `lib/agent_platform/`, and
  `config/agent_platform/manifests/`: discovery tokens/policy already exist; REST
  returns Ruby response hashes; services lazily construct writable engines;
  JobManager has ownership but no capacity/TTL bound.
- `test/agent_platform/gateway_test.rb` and `policy_session_test.rb`: existing
  token/argument/restricted-entity/path/leak-guard/read-only policy contracts.
  Existing search limits before filtering; existing path finds a path before
  privacy filtering. Those are not sufficient for visible-only ranking/traversal.
- `lib/structured_dataset/{database,engine,query,integrations}.rb` and
  `test/dataset/storage_test.rb`: engine schema 3, startup migration, mkdir/WAL,
  validated/bound query helpers, independent Dataset schema history. ActivityAdapter
  also migrates existing storage. Defaults must remain compatible for writers.
- `knowledge_sdk.rb`, configuration, plugin registry, SchemaRegistry: global
  Dataset override/config resolution; current profile detection is directory-based;
  typed schema/template readiness needs an explicit per-feature check.
- Finance reporting/projection/integrations, `test/finance/performance_security_test.rb`,
  Finance report schema and docs: exact decimals, explicit owners, complete-history
  replay, restricted row/identity filtering, supported accounting limitations.
- Capture Store/Search and `test/capture/search_analysis_plugin_test.rb`: canonical
  format does not require a profile; scoring exists but typed literal filters and
  safe detail projection need additive APIs.
- Activity Timeline and `test/activity/timeline_test.rb`: existing projection and
  redacted placeholder semantics; cache writes and fixed 86,400-second local-day
  arithmetic must not be reused unchanged by dashboard reads.
- Orchestration scheduler/runtime/cache and scheduler tests: five-field conjunctive
  matching, no timezone field, durable operational state, notification text without
  reliable per-record sensitivity provenance, cache keys lacking full new read
  dependencies. Read safe summaries and disable derived disk caching by default.

P0 changes none of those subsystems. The linked architecture/API documents specify
which owning phase must address each gap before exposing it to the browser.
