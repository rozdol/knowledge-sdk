# Phase 3 Acceptance Testing

The dependency-free Ruby harness generates a deterministic, realistic synthetic vault outside Git, validates it against the frozen v1.0 model, performs extended graph consistency checks, executes every current Dataview block through a fail-closed compatibility engine, simulates common AI mutations, performs 2,000 stress mutations, and writes six Markdown reports.

Run from the `knowledge-sdk` root:

```text
ruby "acceptance/run_acceptance.rb" --seed pkg-phase3-v1 --run-id run_01KYQ74JP0YFKC2XEC2P2M1C7A
```

The generated vault is rebuilt at `/private/tmp/pkg-acceptance-pkg-phase3-v1`. It is deliberately outside the repository, so generated test data cannot be committed accidentally. The reproducibility boundary is the seed, frozen schema/relationship registry, harness version, and supplied run ID.

Run the fast unit checks separately:

```text
ruby "acceptance/test_acceptance.rb"
```

Dataview's plugin runtime has no official headless API. The compatibility engine dynamically discovers all `dataview` and `dataviewjs` fences, implements the expressions used by the current views, and fails on unsupported syntax. Native Obsidian rendering remains a release smoke test after plugin upgrades.

## Finance CLI smoke acceptance

`ruby acceptance/finance_smoke.rb` creates an independent temporary generic Vault, installs the
optional Finance extension, submits exactly approved synthetic master/ledger proposals, verifies
Microsoft FIFO quantities and P&L through actual CLI commands, and runs `doctor` and `validate`.
The Vault is removed on exit. Detailed financial accounting, missing-history conversation, derivatives,
loan/property, import, return, concurrency, restricted-context and cross-Vault scenarios are in
`test/finance/` and run as part of `bundle exec rake test`.
