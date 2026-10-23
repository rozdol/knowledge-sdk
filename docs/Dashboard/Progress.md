# Dashboard implementation progress

Source of truth for execution: [Implementation Plan](Implementation%20Plan.md).
Session workflow: [Session Guide](Session%20Guide.md).

Updated: 2026-10-23. Planning baseline: `85a0385`.

No implementation phases have started. This document records planning, not an
assertion that a dashboard server, UI, or new capability already exists.

## Phase ledger

Allowed states: `not_started`, `in_progress`, `complete`, `blocked`.
Use `blocked` here only with a concrete dependency and next action; it is a project
ledger value, not an instruction to change any Codex goal status.

| Phase | Deliverable | Dependencies | Status | Evidence / next action |
|---|---|---|---|---|
| P0 | Contracts, dependency evaluation, read-safety design | None | not_started | Next: inspect current code; write Dashboard Architecture/API Contract |
| P1 | Read-safe SDK primitives and optional authenticated HTTP host | P0 | not_started | Wait for P0 contracts |
| P2 | Browser shell and shared widget states | P1 | not_started | Wait for authenticated search vertical slice |
| P3 | Contacts, memory and bounded search | P2 | not_started | Wait for shared shell/API |
| P4 | Finance reports and transactions | P3 | not_started | Wait for shared page patterns |
| P5 | Laboratory history and trends | P4 | not_started | Wait for typed domain read patterns |
| P6 | KG automation, overview and refresh | P5 | not_started | Wait for domain widgets |
| P7 | Integrated verification, packaging and first release | P6 | not_started | Wait for first-release features |

Deferred F1-F7 are not scheduled or authorized implementation tasks. Start them
only when requested after checking their own scope and prerequisites.

## Decisions already established

- Start with the canonically read-only release; no new approval or mutation UI.
- Optional Ruby web host, HTML/CSS/JS frontend, same Agent Gateway as Hermes.
- Single configured Vault per process initially; no browser-supplied storage paths.
- Typed capability additions reuse domain services rather than replacing them.
- Missing/outdated Dataset storage must not be created/migrated by browsing.
- Investment/wealth P&L is initial Finance scope; other meanings are deferred.
- KG schedule inventory first; Hermes/OS inventory requires future adapters.
- No public deployment, external connectors, external models or real private data
  are needed to complete P0-P7.

## Open implementation decisions for P0

- Exact optional web dependency/package versions and compatibility matrix.
- Browser authentication bootstrap and operational state location/lifetime.
- SDK read-only Dataset access design and treatment of older DB schema versions.
- Final typed capability IDs, permissions, payloads, limits and API routes.
- Timezone library/context, cron reporting limitations, date-filter boundaries.
- Self-hosted chart assets, browser testing tools and synthetic performance budgets.

## Session records

### 2026-10-23 — Planning only

- Created Implementation Plan, Session Guide and this ledger.
- Inspected existing Gateway/REST adapter, policies, Dataset initialization, Finance
  integration, Activity and scheduler boundaries to identify implementation gaps.
- No product code, dependencies, commands, manifests or canonical Vault data changed.
- Validation: a Python documentation check passed for local links, balanced code
  fences, final newlines and matching P0-P7 plan/ledger entries. `git diff --check`
  passed. Per-file `git diff --no-index --check -- /dev/null PATH` emitted no
  whitespace diagnostics (exit 1 represents each new file's addition). Final status
  contains only the new `docs/Dashboard/` directory.
- Product test suites and package build were not run: this session added planning
  documents only, with no product implementation or root-documentation changes.
- Next session: P0-a, followed by P0-b if the design work needs a second session.

### Template — copy for each implementation session

```text
Date / phase / session unit:
Status after session:
Starting revision and unrelated user changes preserved:
Prerequisites verified:
Implemented behavior / files changed:
Contracts, permissions, schema or dependency decisions:
Canonical-read-safety and privacy evidence:
Verification commands and exact results:
Required checks not run / failures:
Known limitations or blockers and resolution:
Commit reference (only if made) / uncommitted paths to preserve:
Next session unit and concrete starting point:
Suggested next-session prompt:
```
