# Finance extension implementation report

This is a verified set of Finance vertical slices, not completion of every requested wealth-management
workflow. General ownership/corporate actions, physical option settlement, advanced tax/margin models
and unrestricted financial conversation remain unfinished. No real financial data or attached user
Vault was imported or changed.

## Architecture and changed files

The implementation reuses the existing Graph, Dataset, Proposal, Approval, Engine, Finance analysis,
Planning/Decision, Activity and Gateway. There is one SQLite store and one submission authority.

- `lib/knowledge_finance/`: identity/contracts; security, futures, option and bond accounting adapters;
  immutable schemas and Dataset protection; pure FIFO projections; reports; liquidity candidates;
  proposal adaptation; conversation/state; offline Flex import; plugin integrations; CLI.
- `plugins/finance/`: explicit extension manifest and Financial Owner, Account, Asset and shared
  Dataset schemas. No mandatory companion Vault, ontology or external API is introduced.
- `config/agent_platform/manifests/finance.json`: `kg.finance.read` and `kg.finance.propose` contracts.
- `lib/knowledge_extraction/review_proposal_builder.rb`: shared implementation extracted from the
  existing Capture review-envelope builder. Capture retains its compatibility class and behavior.
- Existing chat/classifier, CLI, Dataset routing/search, analysis, Activity and plugin installation
  modules receive small integration changes. Financial semantics remain inside the plugin. Risk
  classification retains human review for financial records and marks reversals high risk.
- Dataset regular-expression serialization is stabilized so approved schema JSON survives repeated
  round trips. Plugin installation preflights all conflicts and preserves the active profile when
  installing an extension.
- `test/finance/`, `acceptance/finance_smoke.rb`, package/architecture/subsystem documentation, and
  public JSON schemas cover the contracts and verification. No generated gem, runtime database,
  source artifact, registry or synthetic Vault belongs in the change.

## Data contracts and identity

Graph master records contain semantic ownership/account/custodian/instrument identity. Dataset
`finance_events` contains immutable economic operations and correction/deduplication linkage;
`finance_observations` contains owner-scoped price, FX and portfolio observations. Dataset audit columns
retain exact approval, source and Evidence provenance. Every event binds the asset's contract digest;
external contract edits cannot silently change historical multipliers or currencies.

Identifiers are typed, including ISIN, ticker+MIC, IBAN, VIN and IBKR conId. ISIN check digits,
country-specific IBAN lengths/checksum, VIN structure and ticker/MIC structure are validated. Trusted
plugins may register cadastral format validators. Unavailable identifiers remain unavailable; similar
names and symbols never authorize merging. Multiple holdings reference one instrument while retaining
separate owner/account keys. Personal and corporate totals are not automatically combined.

## Accounting, asset coverage and reports

Decimal TEXT and Ruby 2.6 BigDecimal preserve exact native accounting; Float input is refused. Approved
atomic event bundles replay current history before append. FIFO supports long/short lots, partial and
same-day closes, multiple accounts, internal transfers, corrections and historical quantities. Splits
adjust lots and pre-split marks without manufacturing gains. Explicit unknown-basis opening balances
retain null cost basis and null realized P&L.

Supported slices include equities/ETFs/funds, futures daily settlement, option premiums/expiry/cash
settlement, dirty-price bonds and coupons, cash accounts, physical assets and fractional property,
and receivable/payable loans. Loan principal, recorded accrued interest, repayments and overdue
principal stay separate. The main guide states the exact supported operations and exclusions.

P&L reports expose realized gains, variation margin, unrealized changes, income, expenses, fees,
external flows, native currencies and the date range. Missing basis/marks produce partial/null totals.
Sourced observations disclose time, quality, freshness and FX. Net worth retains native components and
known subtotals when conversion/valuation is incomplete. Time-weighted return requires complete
boundary/flow marks; annualized ACT/365 XIRR requires sufficient dated cash flows and a uniquely
bracketed supported pattern. Instrument-specific percentage-return attribution is unavailable.

## Liquidity, conversation and imports

Liquidity runs Finance candidates through the existing Planning, Scenario and Decision Engine. Two
conditional alternatives model cost-first and timing-first cash raising. Explicit costs, verified
current bids, settlement, FX, ownership access, collateral, minimum holdings and account permissions
are required. Derivative accounts additionally require margin/hedge review. An unmet target is a hard
constraint rejection. The output cannot execute trades, sales or bank transfers.

Finance intent registration routes supported messages through `kg chat`; exact queries are also
available through search, analysis and `kg finance`. Missing gold history is tested from clarification
through a follow-up, immutable review proposal, human approval, atomic submission, closed position,
P&L and Activity. Context is isolated by Vault, authenticated actor, source, sender and conversation;
restricted context cannot be resumed by a less privileged caller or downgraded by a later message.
Complex onboarding uses explicit structured requests after clarification rather than invented IDs.

Imports support normalized CSV, JSON and string-decimal XLSX through existing readers. The offline
IBKR Flex subset retains conId, execution IDs, commissions, selected income and timestamps; exact
account/instrument mappings and explicit timezone treatment are mandatory. DTD/entities and unknown
financial sections fail. Snapshot reconciliation reports discrepancies without inventing history.

Example responses, with a registered synthetic instrument and account:

```json
{
  "status": "clarification_required",
  "intent": "finance.close_position",
  "missing_information": ["effective_at", "quantity", "opening_date", "opening_price"],
  "fields": {"price": "4250"},
  "planned_intent_count": 0,
  "execution_authorized": false
}
```

After the synthetic user supplies opening price 4000, quantity 2 and dates, the response is
`awaiting_approval`. Approved submission records two events and realizes `500.0 USD`. Microsoft
acceptance buys 20 at 300 and 15 at 350, sells 5 at 400, then returns 30 shares, FIFO basis 9750 and
realized gain 500 USD; historical holdings before sale are 35 shares.

## Safety and remaining work

All reads are Vault-scoped and restricted rows/references are excluded from ordinary responses,
analysis, Activity Evidence and telemetry. Financial Dataset writes require the exact approved batch,
actor, provenance and current graph contracts. CLI administrative row mutation cannot bypass the
append-only policy. Imported strings never become executable code, validators, policies or approval.
No models, live broker APIs or market-data services receive content.

Unfinished: general ownership changes/look-through consolidation; corporate-action transformations;
physical option exercise/assignment; clean-price bond/accrual tax allocation; automatic loan-interest
scheduling/day counts; FX P&L attribution; tax-lot reporting beyond gross FIFO; fixed/minimum commission,
market-depth/calendar, concentration and portfolio-margin optimization; unrestricted multilingual
financial NLP; automatic bank/vendor statement discovery; and unsupported Flex financial sections.
Current prices/FX must be supplied explicitly; there is no automatic external market-data connector.
Replay is bounded to 100,000 rows per financial Dataset, and truncated analysis history fails explicitly.

## Verification

These results describe the original implementation build, which still used package version 17.0.0.
The release version is corrected to **18.0.0**; see [release verification](Release%2018.0.0.md).

Verified on Ruby **2.6.10**, with synthetic data only:

| Check | Result |
|---|---|
| `bundle exec rake test` | **265 tests, 3,124 assertions; zero failures/errors/skips**, including 33 Finance tests |
| `ruby acceptance/test_acceptance.rb` | **4 tests, 8 assertions; zero failures/errors/skips** |
| Full `acceptance/run_acceptance.rb` | **PASS: 7,724 base notes, 10 Dataview blocks, 2,000 stress operations** |
| `ruby acceptance/finance_smoke.rb` | **PASS**: explicit install, approved writes, chat, search, positions and P&L |
| Synthetic `kg doctor` | **status: ok**, SQLite integrity and registry consistent |
| Synthetic `kg validate` | **OK: generic Obsidian Vault** |
| `git diff --check` and new-file whitespace inspection | **PASS** |
| `gem build knowledge-sdk.gemspec --output ...` | **PASS**, package version 17.0.0; no new dependency |
| Unpacked-gem Finance smoke acceptance | **PASS**, independent package load, plugin resources, doctor, 30 shares and 500 USD realized P&L |

The handoff harness uses synthetic run ID `run_01M5FCCXRCJ9Y7ZDJ37HYTMTHR`. Generated Vaults,
runtime state, full logs/reports and the built gem remain outside the repository. Existing Ruby verbose
warnings and the gemspec's existing missing-homepage warning do not fail verification. No release,
commit, real data import, trade or bank transfer was performed.
