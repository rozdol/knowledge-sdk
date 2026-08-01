# Dataview Report

<!-- BEGIN AGENT-MANAGED: phase-3-acceptance -->
Generated on 2026-07-29 by `run_01KYYKV3VPYC8CBX0GG6SN7QV0` from deterministic seed `pkg-phase12-sdk-extraction-v1`.

## Results

The harness discovered every fenced `dataview` and `dataviewjs` block dynamically. DQL filters, grouping, limits, dates, links, and the current CRM cadence JavaScript were executed against the generated Markdown fixture.

| Source | Engine | Rows | Time | Result | Errors / warnings |
|---|---|---:|---:|---:|---|
| `CRM Dashboard.md:5` | dataview | 80 | 2.78 ms | PASS |  |
| `CRM Dashboard.md:23` | dataview | 76 | 2.00 ms | PASS |  |
| `CRM Dashboard.md:38` | dataviewjs | 299 | 125.10 ms | PASS |  |
| `CRM Dashboard.md:87` | dataview | 2 | 17.09 ms | PASS |  |
| `CRM Dashboard.md:102` | dataview | 25 | 26.13 ms | PASS |  |
| `Query Cookbook.md:7` | dataview | 5 | 3.96 ms | PASS |  |
| `Query Cookbook.md:18` | dataview | 3 | 5.13 ms | PASS |  |
| `Query Cookbook.md:28` | dataview | 1 | 1.89 ms | PASS |  |
| `Query Cookbook.md:39` | dataview | 1 | 2.89 ms | PASS |  |
| `Query Cookbook.md:50` | dataview | 3 | 4.88 ms | PASS |  |

## Slow queries

- `CRM Dashboard.md:38` — 125.10 ms

## Index recommendations

- No disposable index is justified at this fixture size or measured latency.
- Keep relationship folders partitioned by predicate; the current `FROM "Relationships/<predicate>"` queries benefit from that bounded scan.
- At 20,000 canonical notes, or if native Dataview latency exceeds 250 ms for interactive views, benchmark a one-way disposable index keyed by `type`, `record_status`, `predicate`, endpoint IDs, and `starts_at`.

## Runtime boundary

CI uses the dependency-free compatibility executor because Dataview does not expose an official headless runtime. The executor fails closed on unsupported syntax. A final native Obsidian rendering smoke test remains recommended after Dataview plugin upgrades.
<!-- END AGENT-MANAGED: phase-3-acceptance -->
