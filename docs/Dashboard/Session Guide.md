# Dashboard coding-session guide

Use this guide to execute [Implementation Plan](Implementation%20Plan.md) in
separate agentic coding sessions. [Progress](Progress.md) is the handoff ledger.
Only planning documentation exists initially.

## Starting a session

1. Read the repository `AGENTS.md`, `README.md`, `docs/Architecture.md`, and
   `ARCHITECTURE_DECISIONS.md`. Read relevant subsystem docs and tests before edits.
2. Inspect `git status`, the current revision and recent relevant changes. Preserve
   unrelated user work. The baseline in the plan is a reference, not a checkout or
   reset target. Do not assume earlier sessions committed their changes.
3. Read the implementation plan, current Progress ledger and the requested phase.
   Check prerequisite deliverables and evidence; a status label alone is insufficient.
4. After P0, read its Dashboard Architecture/API Contract and decision records. Check
   actual manifests and package versions against those contracts before proceeding.
5. Work only on the requested phase or named session unit. If the phase is too large,
   deliver a coherent slice and leave the phase `in_progress` with a precise next step.
   Do not implement the deferred roadmap merely because it appears in the plan.

The plan does not request automatic subagent delegation or background automation.
Use the current session's user/repository instructions for coordination and Git
workflow. Do not create user-visible chats, send messages, deploy, publish or modify
real Vaults just to complete a handoff.

## Copyable implementation prompt

Replace `P<N>` and the optional session unit with a phase from the ledger:

```text
Implement phase P<N> [optional session unit: P<N>-a] of the saved dashboard plan.

Read AGENTS.md, README.md, docs/Architecture.md, ARCHITECTURE_DECISIONS.md,
docs/Dashboard/Implementation Plan.md, docs/Dashboard/Session Guide.md, and
docs/Dashboard/Progress.md. Read the relevant subsystem docs/tests and any P0
Dashboard Architecture/API Contract before changing code. Inspect current Git
state and preserve unrelated changes.

Verify prerequisites, then implement only this phase/session unit. The first
release is optional and canonically read-only. Keep Ruby 2.6, opaque-token Gateway
dispatch, policy checks, Vault independence and all existing Engine/approval
boundaries. Browsing must not create or migrate Dataset storage. Use synthetic
data only; do not access real private Vaults or external integrations.

Run relevant tests and all repository checks required for the delivered change.
Update docs/Dashboard/Progress.md with files/contracts changed, exact verification
results, limitations, decisions and the next session's starting point. Mark the
phase complete only when its exit criteria and required checks pass. Stop at this
handoff; do not start the next phase, publish, deploy or commit unless requested.
```

For a design-only P0 session, explicitly replace the implementation instruction
with "Complete P0 design artifacts only; do not implement the server or frontend."

## Session units and expected handoffs

| Phase | Suggested units | Handoff evidence |
|---|---|---|
| P0 | a: contracts; b: dependencies/read safety | Concrete Architecture/API Contract, capability mapping, compatibility decision and fixture/performance budgets |
| P1 | a: nonmigrating reads; b: authenticated HTTP host | Read-safety tests, optional launch instructions, auth/Gateway transport integration and denied-write tests |
| P2 | a: shell/API client; b: components/browser QA | Working synthetic search, shared widget states, responsive and hostile-content checks |
| P3 | a: domain read contracts; b: Contacts/Memory UI | Ranking reasons, safe detail/relationship/Capture/Activity views and privacy tests |
| P4 | a: typed Finance reads; b: Finance UI | Existing-report parity, exact decimals, owner/account scope and incomplete-data cases |
| P5 | a: typed lab reads; b: Medical UI | Subject scope, arbitrary analytes, mixed-unit/reference/nonnumeric cases |
| P6 | a: operational reads; b: Home/refresh | Source-aware job status, scheduling semantics, independent widget states and external-edit refresh |
| P7 | a: integrated QA; b: docs/package | Required test outputs, installed-package smoke, limitations and release checklist |

These units indicate reasonable boundaries, not a requirement to finish a whole
phase in one session. Keep earlier established contract names stable or record an
explicit compatible change with updated consumers and tests.

## Ending a session

1. Review the complete diff, `git diff --check`, and `git status`.
2. Update the phase row and add a dated record to Progress using its template.
3. Describe what works now, what remains, and any compatibility/privacy concern.
4. Record exact test commands, results, and required checks that could not run.
   Do not replace evidence with "tests pass" or claim visual QA without inspection.
5. Record a commit only if one actually exists. Otherwise list the uncommitted
   paths the next session must retain. Do not add generated artifacts or secrets.
6. Supply the next phase/session prompt with its concrete starting point. If a
   prerequisite is incomplete, say so and continue that prerequisite in a later
   authorized session rather than implementing downstream assumptions.

Only the human needs to carry the short prompt between sessions; architecture,
status, verification evidence and remaining work should be recoverable from the
repository documents and current code.
