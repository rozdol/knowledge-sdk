# Finance release 18.0.0

SDK version **18.0.0** identifies the Finance & Wealth Management extension. The original Finance
implementation accidentally retained 17.0.0, making server version checks unable to distinguish it
from the bookmark release. The root `VERSION` now drives both the CLI and gem metadata as 18.0.0.
Ruby 2.6 support, existing Vault formats, manifest versions and approval boundaries are unchanged.

This is a local release preparation until the version change is committed and published. No
`v18.0.0` tag or remote release is created by changing `VERSION`.

## Server update

After the version change is published to `main`, run under the same Unix user and Ruby environment
used by Hermes:

```sh
curl -fsSL https://raw.githubusercontent.com/rozdol/knowledge-sdk/main/update.sh | sh -s -- --ref main
kg version
kg --vault /path/to/vault finance help
kg --vault /path/to/vault gateway capabilities
```

`kg version` must report 18.0.0. Discovery should include `kg.finance.read` and
`kg.finance.propose` for an appropriately permitted identity. Source-checkout users can build and
install the package directly:

```sh
gem build knowledge-sdk.gemspec
gem install ./knowledge-sdk-18.0.0.gem
```

Install Finance once per selected Vault with `kg --vault /path/to/vault plugin install finance` if
its schemas are not already installed, then run `doctor` and `validate`. There is no automatic
financial Dataset migration or schema reinstall during a package update. Existing Finance Datasets
remain unchanged; new Datasets still require exact approved lifecycle Intents. Restart long-running
Hermes processes and refresh capability discovery after updating their runtime.

The optional dashboard companion derives its version and exact core dependency from the same
`VERSION`; dashboard deployments must build/install the matching 18.0.0 companion. Ordinary CLI and
Hermes use do not require the dashboard.

## Verification

Verified on Ruby 2.6.10 using synthetic data:

| Check | Result |
|---|---|
| Installer, updater and lifecycle tests | 10 tests, 61 assertions; passed, including 17.0.0 to 18.0.0 update |
| `bundle exec rake test` | 282 tests, 3,278 assertions; zero failures/errors/skips |
| `ruby acceptance/test_acceptance.rb` | 4 tests, 8 assertions; passed |
| Full synthetic release harness | PASS: 7,724 base notes, 10 Dataview blocks, 2,000 stress operations |
| Core and optional dashboard gem builds | Both 18.0.0; companion requires exactly core 18.0.0 |
| Isolated installed core gem | `kg version` reports 18.0.0 and both Finance capabilities are present |
| Packaged Finance smoke test | Passed; synthetic doctor, validation, holdings and P&L checks |
| `git diff --check` | Passed |

The release harness run is `run_01M5T0XGTX026KB2FQYP3FGVS8`. Packages, logs and synthetic Vaults
are outside the checkout. The original Finance implementation's historical results remain in
[Implementation Report](Implementation%20Report.md). This validation does not publish a release,
push a commit or update any server.
