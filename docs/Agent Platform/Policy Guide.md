# Policy Guide

## Central evaluation

Every discovered or executed capability passes through `PolicyEngine`. Policies may use agent identity, permissions, explicit capability allow/deny lists, session ownership, environment mode, feature flags, an optional time-policy callable, manifest effects and risk, and proposal approval state.

Discovery performs static evaluation and omits denied capabilities. Execution repeats policy after validating the exact token, session, and arguments. Discovery is therefore a usability boundary, not an authorization cache.

## Permissions

Core permissions are:

- `graph:read`, with `graph:private` for contact points and `graph:restricted` for restricted entities;
- `intelligence:read`;
- `proposal:create`, `proposal:read`, and `proposal:submit`;
- `telemetry:read_all` for administrative cross-agent trace access.

Exact permissions, `*`, and prefix wildcards such as `graph:*` are supported. Production identities should receive the smallest explicit set.

## Effects and environments

Manifest effects are `read_only`, `proposal_write`, or `graph_write`. A `read_only` environment hides and denies the latter two. Feature flags can disable individual capability IDs without changing manifests or Gateway code.

## Approval

`none` requires no proposal approval. `proposal_only` permits creating an immutable review artifact but never execution. `existing_proposal_approval` requires the manifest-declared proposal-ID argument and a stored receipt whose fingerprint matches the exact immutable proposal.

`kg.proposals.submit` is the only core `graph_write` capability. Central policy checks the exact receipt before dispatch. `ProposalSubmitter` verifies it again, adds Engine-gated human approval only to covered Intents, and sends each allowed Intent through `Engine#execute`. A policy permission can never bypass the existing approval pipeline.

## Denials

Denied execution returns `status: denied`; missing immutable approval returns `status: approval_required`. Telemetry stores the decision, required approval class, agent ID, capability ID, and trace metadata, but not arguments or proposal content.
