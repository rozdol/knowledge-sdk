# knowledge-sdk-dashboard

Optional Ruby 2.6-compatible, authenticated loopback host for the knowledge-sdk
read API. This component depends on the matching core version; ordinary CLI use
does not require it. P1 includes authentication, bounded Gateway entity search,
availability and safe owned-job metadata. The browser application starts in P2.

Build from this directory with `gem build knowledge-sdk-dashboard.gemspec`, after
building/installing the matching core gem. Run the companion tests from the checkout
root with `ruby -Ilib -Ioptional/dashboard/lib -e 'Dir["optional/dashboard/test/*_test.rb"].sort.each { |f| require File.expand_path(f) }'`.
All fixtures are synthetic. Development requires minitest from the core development
environment; tests are not needed by installed users.

See the packaged core documentation `docs/Dashboard/Operator Guide.md` for launch,
secret provisioning, same-origin authentication, permission settings, storage
recovery, limits and supported routes. Installation does not publish a service or
modify an attached Vault. There are no canonical write, approval or external-fetch
routes.
