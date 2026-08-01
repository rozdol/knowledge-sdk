# Performance Report

<!-- BEGIN AGENT-MANAGED: phase-3-acceptance -->
Generated on 2026-07-29 by `run_01KYYKV3VPYC8CBX0GG6SN7QV0` from deterministic seed `pkg-phase12-sdk-extraction-v1`.

## Benchmark summary

Benchmarks ran on the local acceptance host against 7724 base canonical notes and 5200 relationship records. Wall times use a monotonic clock and are environment-specific.

| Operation | Time | Assessment |
|---|---:|---|
| Deterministic vault generation | 3966.78 ms | acceptable (≤ 30s) |
| Core validator, base fixture | 2123.76 ms | acceptable (≤ 10s) |
| Extended graph analysis/statistics | 3448.39 ms | acceptable (≤ 10s) |
| All Dataview compatibility queries | 193.74 ms | acceptable (≤ 2s) |
| Relationship traversal | 8.91 ms | acceptable (≤ 1s) |
| Duplicate detection | 4.35 ms | acceptable (≤ 1s) |
| Graph statistics projection | 0.04 ms | acceptable (≤ 2s) |
| AI simulation, 8 validator-gated operations | 55148.89 ms | acceptable (≤ 90s) |
| Stress simulation, 2000 mutations | 151380.56 ms | acceptable (≤ 300s) |

## Stress validation

- Batch size: 100 operations
- Validated batches: 20
- Mean batch validation: 5139.91 ms
- Maximum batch validation: 6152.63 ms
- Failed batches: 0
- Mutation mix: add_relationship=414, archive_meeting=403, create_meeting=416, merge=4, remove_relationship=372, rename=8, update_metadata=383

## Scale interpretation

The fixture remains below the frozen model's 20,000-note disposable-index gate. Current validation and traversal costs are acceptable for the target personal-vault scale. Re-run this benchmark on the production machine after major Obsidian, Ruby, or filesystem changes; iCloud synchronization can materially affect cold-cache latency.
<!-- END AGENT-MANAGED: phase-3-acceptance -->
