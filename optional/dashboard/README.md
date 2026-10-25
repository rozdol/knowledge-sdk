# knowledge-sdk-dashboard

Optional Ruby 2.6-compatible, authenticated loopback host for the knowledge-sdk
read API. This component depends on the matching core version; ordinary CLI use
does not require it. P3 adds typed Contacts, Captures and Knowledge Activity reads
to the responsive login/Home/category shell, independent search sources and safe
record/source drawer. Finance, laboratory and automation widgets remain unavailable. P1 authentication,
availability and safe owned-job metadata remain the server boundary.

Build from this directory with `gem build knowledge-sdk-dashboard.gemspec`, after
building/installing the matching core gem. Run the companion tests from the checkout
root with `ruby -Ilib -Ioptional/dashboard/lib -e 'Dir["optional/dashboard/test/*_test.rb"].sort.each { |f| require File.expand_path(f) }'`.
All fixtures are synthetic. Development requires minitest from the core development
environment; tests are not needed by installed users.

Browser tests are development-only: run `npm ci` in this directory, then
`npx playwright install chromium firefox` and `npm test`. Node >=18 is required
only for this tooling; Node 22.13.1 and Playwright 1.56.1 are the P0 pins. The Ruby
fixture must be able to load the optional gems (use GEM_PATH for an isolated install).
The tests cover 1440x900 and 390x844 layouts on Chromium and Firefox with temporary
synthetic Vaults. Generated traces/screenshots go to ignored `output/playwright/`.
Production assets are native JS/CSS/SVG and add no Node or chart runtime dependency.

See the packaged core documentation `docs/Dashboard/Operator Guide.md` for launch,
secret provisioning, same-origin authentication, permission settings, storage
recovery, limits and supported routes. Installation does not publish a service or
modify an attached Vault. There are no canonical write, approval or external-fetch
routes.
