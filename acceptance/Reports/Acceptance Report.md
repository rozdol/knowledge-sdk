# Phase 3 Acceptance Report

<!-- BEGIN AGENT-MANAGED: phase-3-acceptance -->
Generated on 2026-07-29 by `run_01KYYKV3VPYC8CBX0GG6SN7QV0` from deterministic seed `pkg-phase12-sdk-extraction-v1`.

## Outcome

**PASS** — the deterministic fixture passed the schema validator, extended consistency checks, all current Dataview compatibility executions, AI mutation gates, and stress validation.

Generated test data lives at `/private/tmp/pkg-acceptance-pkg-phase12-sdk-extraction-v1` and is intentionally outside Git. Reproduce it with the command in `acceptance/README.md`.

## Acceptance gates

| Gate | Result | Evidence |
|---|---:|---|
| Core schema validation | PASS | OK: 8193 canonical notes, 19 entity schemas, 39 predicates |
| Extended consistency | PASS | 0 errors |
| Broken links / backlinks | PASS | 0 / 0 |
| Duplicate ULIDs / identities | PASS | 0 / 0 |
| Predicate and direction checks | PASS | 0 / 0 |
| Family and date invariants | PASS | 0 / 0 |
| Dataview blocks | PASS | 10 executed, 0 errors |
| AI operation simulation | PASS | 8 operations, validator after each |
| Stress mutations | PASS | 2000 operations in 20 validated batches |
| Graph cohesion | PASS | 1 component(s), 100.00% in largest |
| Performance | PASS | validation 2123.76 ms; generation 3966.78 ms |

## Base fixture

The frozen schema has no separate Restaurant entity. The requested 120 restaurants are represented as `place` notes with `place_kind: restaurant`; the remaining 80 are other Place records. Likewise, 120 companies and 20 other organizations share the `organization` type.

| Canonical type / subtype | Count |
|---|---:|
| people | 300 |
| companies | 120 |
| other organizations | 20 |
| cities | 70 |
| countries | 40 |
| projects | 100 |
| meetings | 800 |
| interests | 200 |
| technologies | 150 |
| restaurants | 120 |
| other places | 80 |
| events | 80 |
| books | 50 |
| introductions | 150 |
| promises | 100 |
| follow-ups | 100 |
| languages | 12 |
| professions | 20 |
| industries | 12 |
| relationship | 5200 |

## AI operations

| Operation | Result | Validator-gated time |
|---|---:|---:|
| Create person | PASS | 5449.98 ms |
| Merge duplicate | PASS | 5625.65 ms |
| Update company | PASS | 5647.98 ms |
| Rename company | PASS | 8699.26 ms |
| Add meeting | PASS | 6173.38 ms |
| Move project | PASS | 8750.49 ms |
| Archive entity | PASS | 5734.35 ms |
| Link entities | PASS | 9067.64 ms |

## Discovered weaknesses

- Dataview has no official headless execution API; automation therefore uses a fail-closed compatibility executor and cannot prove Electron rendering behavior.
- Relationship records are excellent canonical facts but create visual two-hop clutter when displayed directly in Obsidian's global graph.
- Cold-cache performance on iCloud-backed storage can differ from this `/private/tmp` benchmark and should be sampled on the production vault.

## Recommendations

- Run a native Obsidian smoke test after Dataview plugin upgrades; retain this compatibility suite as the deterministic CI gate.
- Hide Relationship and old Meeting notes in the global graph, using local graphs and predicate views for investigation.
- Keep the 20,000-note scale gate; add only a disposable one-way index if native query latency exceeds 250 ms.
- Run this acceptance suite before schema migrations and compare benchmark deltas against the committed Phase 3 baseline.
<!-- END AGENT-MANAGED: phase-3-acceptance -->
