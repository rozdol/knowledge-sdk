# Finance & Wealth Management

SDK release: **18.0.0**. See [release notes](Release%2018.0.0.md) for upgrading servers.

The optional `finance` plugin extends the existing Knowledge Graph, Structured Dataset Engine,
Proposal/Approval/Engine, Phase 13 Finance analysis plugin, Planning/Decision Engine and Knowledge
Activity. It has no broker connection, order execution, bank-transfer capability, independent database,
or independent approval system. All examples and acceptance data are synthetic.

## Installation and authority

```sh
kg --vault /path/to/vault plugin install finance
```

Installation adds trusted semantic schemas for Financial Owner, Financial Account and Financial Asset,
plus the shared Dataset schema. Identical shared Dataset schema files are reused; any conflicting file
aborts installation before copying. Finance is an extension, so installation preserves an existing
profile and its validator. Plain `kg init`, attach and detach do not install Finance. A plain generic
Vault can use Finance without installing the CRM profile.

Natural language, normalized statement files and structured chat requests create review proposals.
Review, exact approval and submission remain separate operations:

```sh
kg proposal export proposal_<ULID> --format json
kg proposal approve proposal_<ULID> --all --actor finance-reviewer
kg proposal submit proposal_<ULID>
```

Finance never claims a change is
saved while it is only proposed. There is no `finance execute` or automatic recommendation execution.

## Storage and identity

Semantic master data is ordinary canonical Markdown under the installed schema's folders. Graph
creation uses `CreateEntity` through the existing Engine. An immutable internal ID identifies each
asset independently of its name and its account-specific positions. An owner must identify an
existing Person, Organization, or Financial Owner. A Financial Owner declares `personal` or
`corporate`; reports require one explicit owner scope when more than one is possible.

An asset has `asset_class`, `owner_ids`, currency, unit, multiplier, identification status, provenance,
`identifiers_json` and `details_json`. These JSON strings preserve flat frontmatter compatibility.
They contain semantic contract terms, never transaction histories or materialized positions. Accounts
have explicit owners, typed identifiers and optional custodian/availability terms. Asset/account
identity and economic contract terms cannot be overwritten through `UpdateEntity`; register an
explicit successor when contract terms change. Names can still use the existing rename operation.
Unknown human frontmatter and Markdown body bytes remain governed by the Engine's preservation rules.
Financial identities cannot be automatically merged.

Typed identifiers include ISIN, FIGI, CUSIP, SEDOL, ticker+MIC (`MSFT:XNAS`), IBKR `conid`, futures and
option contract references, IBAN, bank/broker account IDs, jurisdiction-qualified cadastral IDs, VIN,
registration, agreement, certificate, serial and user-assigned references. ISIN structure and Luhn,
IBAN country length and mod-97, VIN structure, and ticker+MIC structure are checked. Unsupported IBAN
jurisdictions fail closed. IBAN format validation is not account verification. VIN check digits are
not globally enforced because jurisdictions differ. Exact broker conIds are preserved. Trusted code
can register jurisdiction-specific cadastral validators with `KnowledgeFinance.identifiers`;
otherwise jurisdiction and a nonempty cadastral value are retained without claiming local format
verification. Other typed identifiers are retained as asserted references, without inventing them or
claiming independent verification. Similar names and tickers produce candidates, never merges.

One instrument ID can occur in multiple separate owner/account position keys. Direct, fractional and
joint holdings use explicit owner/account events. `ownership_share` quantities are bounded to zero
through one across recorded holders during full replay. Beneficial/corporate ownership and collateral
may be retained as semantic metadata; legal look-through consolidation and general ownership-transfer
events are not yet implemented. Owner scopes are never silently consolidated.

## Financial Datasets and precision

`finance_events` and `finance_observations` are registered through the existing autonomous Dataset
lifecycle proposal. No Dataset or row is provisioned while interpreting a statement. Their immutable
1.0.0 templates are registered in the existing Template Registry. The generic delimited parser is
available for inspection; Finance imports intentionally use the stronger approved-batch path rather
than generic `InsertDatasetRow` writes.

`finance_events` contains immutable event and deduplication IDs; operation; effective and booking UTC
timestamps; optional settlement date; deterministic sequence; owner, account and asset IDs; quantity,
unit, currency, price, amount and fees; external event ID; transfer/correction/reversal links;
sensitivity; and operation metadata. The Dataset's existing audit columns add source, Evidence,
source URI/filename, proposal, approval, actor and Intent references. Rows remain in the same
`.knowledge/datasets.sqlite3` store as other Datasets. Every financial event is not a graph note.

Exact quantities, prices, amounts, fees and rates are decimal **TEXT**, calculated using Ruby
`BigDecimal`. JSON monetary values must be quoted strings. Floats, scientific notation, nonfinite
values and excessively large inputs are refused. Original decimal strings and currency remain in
rows, with the full supplied rendition in local Evidence. Computed values use ordinary decimal
notation; return estimates are rounded to 12 decimal places. There are no exact financial REAL or
SQLite floating-point SUM calculations. Currency conversion requires an actual sourced FX
observation; no synthetic rate is substituted.

`AppendFinanceRows` is one immutable Dataset Intent containing an atomic event bundle. The existing
Submitter attaches the Dataset handler, and the existing Engine validates the Vault before its
deferred Dataset operation. The Dataset extension rechecks the exact proposal fingerprint, approved
Intent, actor and exact rows. Under the Dataset Engine's `BEGIN IMMEDIATE` transaction it deduplicates,
replays the entire affected history, and inserts the complete valid bundle or nothing. Changes since
review that make a close impossible fail at execution. Per-row deterministic child Intent IDs retain
the store's existing unique receipt index; the approved parent batch is retained in Engine audit.
Graph prerequisites remain dependency-ordered individual Engine transactions. A batch failure can
leave an already approved empty Dataset or master identity, matching existing proposal semantics.

All Dataset insert/import/update/replace/delete/evolve/migration entry points enforce this policy,
including calls made with a Dataset ID instead of its slug. Generic unapproved financial row writes
are refused. Corrections retain the original event and append a linked reversal plus replacement.
Reversing an opening whose later closes would become invalid fails replay. A reversal of a transfer
must retain balanced legs. Reversal chains and repeated reversal of the same event are refused.
Reversal effective time controls when replay excludes the original; historical reports are economic
history, not a separate bitemporal “what was known then” reconstruction. To restate the original
period, give correction/reversal events that period's effective timestamps and today's booking time.

Deduplication uses explicit keys or source/account/external-event identity. Without an external ID,
the interpreter fingerprints the supplied economics. Distinct identical fills need distinct external
IDs or explicit deduplication keys. Matching repeated economics is a no-op; a reused external key with
changed economics is an error. Existing rows and provenance are never silently replaced.

## Accounting and supported slices

Positions, cash balances, outstanding loans and lots are reproducible projections; there is no
independent editable positions table. FIFO is the initial policy; other policy names are refused.
Effective timestamp, explicit sequence and immutable event ID define replay order. Imports containing
same-timestamp operations must supply an appropriate sequence. Every event binds an immutable asset contract digest; external contract edits fail replay rather than
reinterpreting multipliers or currencies. Pre-split marks are adjusted only by recorded account-specific
splits, and liquidity requires a bid after the last split. Original opening events remain, so
future cost-basis methods can reconstruct original lots.

| Asset slice | Verified behavior |
|---|---|
| Stocks, ETFs, mutual funds | Long/short FIFO, partial closes, multiple lots/accounts, dividends, fees, tax withholding, splits, historical holdings |
| Futures | Explicit multiplier, no purchase-price cash debit, exact daily variation-margin reconciliation, reset settlement basis, partial closes, no double counting of settled P&L |
| Options and futures options | Premium/multiplier accounting, long/short legs, partial closes, expiry, cash-settled exercise/assignment from explicit underlying settlement value |
| Bonds | Explicit dirty price per 100 nominal with multiplier `0.01`, coupon income, purchase/disposal and native total P&L |
| Precious metals, commodities | Explicit units, FIFO acquisitions/disposals and sourced valuations |
| Bank/broker/cash accounts | Deposits, withdrawals, cash balances and paired internal transfers; transfers do not create investment income |
| Property, land, vehicles, collectibles, artworks, movable assets | Identity/ownership metadata, fractional acquisition/disposal, explicit valuations, rental income and maintenance expenses |
| Loans, credit cards, credit facilities | Receivable/payable direction, creditor/debtor identity, principal disbursement/repayment, separately recorded accrued/paid interest, schedules, due dates and overdue principal |

Each instrument adapter uses the common cash/valuation reporting contract. Security, futures,
options and bond adapters are distinct trusted objects; extensions can register another adapter.
Futures market value for net worth is unsettled P&L, with notional reported separately. It is not
withdrawable cash. Bond dirty-price P&L is economic return, not tax allocation of clean-price gains
versus accrued interest. Clean-price accrual, physical option settlement, automatic rolls,
mergers/spin-offs and general corporate/ownership action transforms are not implemented. Reserved
operation names fail explicitly and must not be interpreted as completed support. Loan accrual is
based on explicit accrual events; automatic day-count/compound-interest generation is unavailable.

Investment P&L separates FIFO gross realized gains, variation margin, change in unrealized P&L,
income, expenses and fees. Fees are expensed at the event date, outside gross lot basis. Opening fees
are not silently allocated as tax basis. Deposits/withdrawals are external flows, and internal
transfers are neither flows nor income. Native currencies remain separate in P&L; FX attribution,
full tax-lot reporting and automatic tax calculations are unavailable. Historical reports never use
a future price. Missing marks or basis yield a partial report with null net P&L. Unknown basis is
never zero. Per-instrument ranking remains separated by native currency.

## Valuation and performance

`finance_observations` stores immutable owner-scoped price, FX and complete-portfolio observations:
observation key/type, asset where applicable, decimal value, currency/base currency, price type,
`as_of`, `retrieved_at`, quality, sensitivity, metadata and normal Dataset provenance. Price types
include bid/ask/last, appraisal, market estimate, user estimate, confirmed sale and portfolio close.
The latest supplied observation at or before the requested instant is selected. A deterministic
24-hour freshness threshold is disclosed. Liquidity bids use a stricter 15-minute threshold. No live
quote or FX connector is enabled or required.

Net worth includes recorded positions, cash and loan principal/accrued interest. It exposes each
native component and conversion source/rate/time. Missing valuations or FX make exact `net_worth`
null while retaining the known subtotal. Stale and estimated values are identified at component and
report level. Coverage is explicitly limited to policy-visible recorded history, not all real assets.
EUR is the suggested reporting default; `--currency` changes reporting without changing native
account currencies.

Monthly P&L uses inclusive declared date bounds and historical endpoint marks. Time-weighted return
requires exact complete-portfolio boundary valuations and, for every external flow, verified
before/after-flow observations linked by `metadata.flow_event_id`, `metadata.phase: before_flow` or
`after_flow`. Their difference must reconcile exactly to the flow. XIRR uses dated initial/final
portfolio values and external flows, ACT/365 and bounded decimal bisection. It is annualized; TWR is
a period return fraction (`0.21` means 21%). Multiple-sign-transition cash-flow patterns and
unbracketed XIRR roots are unavailable. Missing inputs return explicit unavailable statuses; Instrument-specific percentage-return attribution is not implemented. P&L is
never divided by today's value as a substitute.

## Conversation and queries

English, Russian and practical Greek patterns register through the existing IntentClassifier. Chat
uses trusted intent-to-capability registrations, not financial semantics embedded in its router.
`kg.finance.read` and `kg.finance.propose` are manifest-discovered Gateway capabilities. Natural
finance messages reach them before generic graph observation, Capture or weak table parsing. Explicit
note wrappers and existing expense routing retain their behavior.

```sh
kg chat --text 'Я купил 30 акций Microsoft по 420 долларов' --json
kg chat --text 'Сколько у меня акций Microsoft?' --json
kg chat --text 'Кто мне должен?' --json
kg chat --text 'Какие акции Microsoft у меня были в январе прошлого года?' --json
kg chat --text 'Что принесло мне наибольшую прибыль за прошлый квартал?' --json
kg chat --text 'Что мне продать, чтобы быстро получить 70,000 EUR?' --json
kg analyze 'Monthly investment P&L for the past year' --json
```

A financial write with missing identity/account/trade date/quantity/price clarifies before producing
an executable proposal. A ticker alone is not globally unique. Names and aliases only select exact
registered candidates. The current bounded parser recognizes straightforward trade shapes; it is
not unrestricted financial NLP. Complex debt/property onboarding returns clarification and accepts
an explicit structured request through the same `kg chat --file` or `kg finance propose --file`
path. It does not fabricate counterparties, titles, accounts or acquisition history.

The missing-gold workflow is tested end to end. With a registered unambiguous gold instrument and
account, `Я закрыл позицию по золоту по 4,250.` retains `price: "4250"` and asks only for missing
quantity, closing timestamp and opening date/price. It never assumes one contract or zero basis.
Use the same `--conversation` and `--sender` for follow-ups:

```sh
kg chat --conversation synthetic-gold --sender synthetic-user \
  --text 'Я закрыл позицию по золоту по 4,250.' --json
kg chat --conversation synthetic-gold --sender synthetic-user \
  --text 'finance details: opening_date=2026-08-01 opening_price=4000 quantity=2 effective_at=2026-09-01T12:00:00Z' --json
```

State is derived local runtime data scoped by Vault, authenticated Gateway actor, transport, conversation
and sender. Restricted clarification context requires restricted permissions and retains its sensitivity
when a later message resumes it. The response
also contains the retained original text and known fields. When no opening exists, supplied opening
facts and the close become one approved atomic batch. Explicit `basis_status=unknown confirmed=true`
selects an opening-balance event with null basis; the actual opening/as-of date is still required.
No opening-balance event implies historical acquisition cash flows.

For a registered asset/account/owner, this structured chat request is unambiguous:

```json
{"finance":{"rows":[{
  "operation":"BUY","effective_at":"2026-01-02T12:00:00Z",
  "owner_id":"financialowner_<ULID>","account_id":"financialaccount_<ULID>",
  "asset_id":"financialasset_<ULID>","quantity":"20","unit":"share",
  "currency":"USD","price":"300","fees":"1"
}]}}
```

Registration uses `{"finance":{"kind":"asset","attributes":{...}}}` (`kind` also supports `owner`
and `account`). Supply `name`, owner IDs and the class-specific fields above. For instrument-specific
contract terms use `details`; for typed identifiers use an array `identifiers`. The result supplies
the proposed immutable entity ID. Registration and its financial events currently require separate
review proposals. Unknown simple registration statements do not silently become Graph observations.

## Liquidity planning

`kg finance liquidity --owner ID --target 70000 --currency EUR --deadline 2026-10-25` uses an installed
Finance candidate generator inside the existing Planning Engine, Scenario Evaluator and Decision
Engine. It produces cost-first and timing-first conditional alternatives, exact net modeled cash,
review steps, assumptions, missing inputs and constraint violations, with no generated trade Intents.
An unmet target is a constraint rejection. Deadline bounds use explicit modeled calendar days.

Accounts must supply explicit `details.liquidity`: `accessible`, `permissions_confirmed`,
`settlement_days`, `commission_rate`, `fx_cost_rate`, and, for cash,
`withdrawable_cash_confirmed: true`. Securities also require `unit_step` and a current verified bid.
Rates are decimal fractions. Optional `tax_rate` is an explicitly supplied proceeds-based scenario
cost, not a tax calculation. Missing tax assumptions remain a review concern. Collateral restrictions
exclude candidates. Accounts with derivatives require `margin_review_confirmed` even when selling
ordinary shares or using cash. Derivatives and illiquid assets without an appropriate liquidation
model remain unresolved inputs. Pledged asset metadata also blocks liquidation.

The Ruby adapter accepts `exclude_assets` and per-asset `minimum_holdings` constraints. Unsupported
constraints fail rather than disappear. Concentration optimization, portfolio margin calculation,
exchange settlement calendars, fixed/minimum commissions, executable-depth modeling and tax-aware
optimization are unfinished. No scenario claims that quotes, permissions or cash remain executable.

## Imports and reconciliation

```sh
kg finance import --file synthetic-transactions.csv --source synthetic-bank --json
kg finance import --file synthetic-transactions.json --json
kg finance import --file synthetic-transactions.xlsx --json
kg finance import --file synthetic-flex.xml --owner OWNER_ID --account ACCOUNT_ID \
  --statement-offset +02:00 --json
kg finance reconcile --file synthetic-snapshot.json --owner OWNER_ID --as-of 2026-09-30 --json
```

CSV/JSON/XLSX require the normalized financial event/observation columns. XLSX reuses the existing
Dataset reader; exact decimal cells must be stored as strings because numeric floating-point cells
are refused. Files are bounded to 10 MB and 10,000 rows. Imported provenance/approval columns are
refused. Original artifact URI and a complete normalized rendition are retained in local Evidence.
No arbitrary bank statement layout is guessed.

The offline Flex subset supports exact-mapped trades/executions/commissions and selected dividends,
coupons, interest, fees and withholding tax. A registered `broker_account` must match the statement,
and every conId must identify exactly one registered asset. Opening/closing direction, commission
currency and execution ID are required. ISO timestamps need an offset; ordinary Flex broker-local
timestamps require an explicit statement offset. DST-spanning exports should normalize each timestamp
instead. DTD/entity declarations and unsupported financial sections are refused. Flex position
snapshots, variation-margin sections, corporate actions, FX-trade normalization and broad vendor bank
parsers are unfinished. Normalize those records explicitly rather than assuming support. There is
no live broker API dependency.

Snapshot reconciliation compares explicit owner/account/asset/currency quantities with event replay,
returns discrepancies and unresolved history, and creates no opening transactions or cost basis.
It is read-only; snapshot age/scope is supplied by the caller.

## Privacy, limits and recovery

All reads remain Vault-scoped. Restricted records/rows and referenced restricted identities are
excluded from ordinary reports, analysis and candidates. Restricted references cannot be downgraded
by a private event or identity. Restricted Finance reads require **all** of `finance:restricted`,
`graph:restricted` and `dataset:restricted`. Ordinary Finance capabilities require appropriate read or
proposal permissions. Generic Dataset search also checks Finance read permission. Telemetry includes
capability/status metadata, not financial content. Activity redacts restricted proposal Evidence.
No source content is sent to external models, broker APIs or market services.

Evidence, proposals, approvals, runtime clarification state, receipts, SQLite and audit logs are local
sensitive user data. Keep `.knowledge/` out of version control and protect backups. SDK audit retains
approved Intent payloads locally for recovery; it is not a public telemetry log. Back up canonical
Markdown, immutable source Evidence, SQLite using a consistent SQLite backup/checkpoint procedure,
and runtime approval/receipt/audit state together. Restore to a separate location and run `doctor`,
`validate`, and snapshot reconciliation before resuming writes. Do not edit SQLite ledger rows to
repair history: propose linked corrections. No destructive Finance migration is included.

Replay currently reads at most 100,000 rows per Dataset and fails explicitly beyond that bound.
Cross-knowledge analysis refuses a truncated financial context instead of reporting incomplete
quantities as complete. Reports expose coverage limitations; no exact claim is made about unrecorded
assets or the user's legal/tax position.

Machine-readable contracts: `finance-event.schema.json`, `registration.schema.json`,
`finance-report.schema.json`, both Dataset definitions, and
`config/agent_platform/manifests/finance.json`. See `Implementation Report.md` for verified scenarios
and remaining gaps.
