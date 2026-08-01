# Graph Health Report

<!-- BEGIN AGENT-MANAGED: phase-3-acceptance -->
Generated on 2026-07-29 by `run_01KYYKV3VPYC8CBX0GG6SN7QV0` from deterministic seed `pkg-phase12-sdk-extraction-v1`.

## Automated readability assessment

| Signal | Result | Value | Threshold |
|---|---:|---:|---:|
| Disconnected islands | PASS | 1 components | 1 |
| Orphans | PASS | 0 | 0 |
| Huge hubs | PASS | 0 | 0 above max(150, 5% of nodes) |
| Over-connected nodes | PASS | 0 | 0 above degree 150 |
| Under-connected nodes | REVIEW | 124 | 0 below degree 2 |
| Largest component | PASS | 100.00% | at least 99% |

## Highest-degree nodes

| Node | Degree |
|---|---:|
| `People/Self` | 71 |
| `Concepts/Languages/Dutch` | 50 |
| `Concepts/Languages/German` | 50 |
| `Concepts/Languages/Greek` | 50 |
| `Concepts/Languages/Korean` | 50 |
| `Concepts/Languages/Spanish` | 50 |
| `Concepts/Languages/Swedish` | 50 |
| `People/Maya Baker` | 45 |
| `People/Alex Martin` | 42 |
| `People/Maya Clark` | 41 |

## Readability recommendations

- Use Obsidian Graph groups for People, Organizations, Interactions, and Relationship records; hide `_System` and Attachments.
- For day-to-day exploration, exclude `Relationships/` notes from the global visual graph and use local graphs at depth 2. Relationship notes are canonical edges but visually double the path length.
- Filter `Interactions/Meetings` by date when exploring long-lived contacts; 800 meetings are intentionally dense temporal evidence.
- Preserve predicate partitioning and avoid persisted inverse edges, which would double clutter without adding facts.
<!-- END AGENT-MANAGED: phase-3-acceptance -->
