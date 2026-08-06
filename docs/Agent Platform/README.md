# Agent Platform

Phase 7 adds the only supported public integration boundary for Hermes, MCP tools, future network APIs, Web UI, mobile clients, and autonomous or semi-autonomous agents. The stable Engine, Knowledge Extraction, and Knowledge Intelligence layers remain unchanged beneath it.

## Core invariant

Agents do not call Ruby classes, files, Markdown, YAML, or arbitrary capability-name strings. They discover policy-allowed Capability Manifests and invoke the opaque token issued for a specific manifest digest and version.

```text
Hermes / MCP / CLI / REST-style client
                 |
        policy-filtered discovery
                 |
        opaque invocation token
                 |
          Agent Gateway
                 |
 Registry -> Policy -> Session -> private handler binding
                 |
 GraphReader / Extraction / Intelligence / Planning / ProposalSubmitter
                 |
       Engine for approved writes only
```

The CLI necessarily accepts a textual selector, but it resolves that selector against discovery before invoking the Gateway. The public Gateway request contains only the opaque token, not a handler name.

## Implemented components

- Versioned JSON Capability Manifests with typed input/output schemas, errors, effects, timeouts, permissions, risk, approval, examples, transports, and deprecation metadata.
- Registry validation, duplicate rejection, version selection, opaque tokens, and compatibility checks.
- Immutable agent identities, requests, responses, sessions, and bounded reference-only working memory.
- Central policy for permissions, agent allow/deny lists, environment mode, feature flags, session ownership, optional time policy, and exact proposal approval.
- Request-scoped memoization, timeout enforcement, typed errors, reasoning envelopes, and output leak prevention.
- Sanitized bounded telemetry and agent-owned trace inspection.
- In-memory asynchronous jobs for long read operations. Sessions and jobs are operational state, never graph truth.
- Hermes, MCP, REST-style, and CLI adapters generated from the same discovered manifests.
- Trusted plugin registration that separates public manifests from private Ruby handlers.
- Manifest-driven Markdown reference and Ruby SDK generators.

## Core capabilities

Thirty-two active contracts cover entity and company/project search, entity retrieval, relationship paths, deterministic graph queries, Capture search and proposal creation, Dataset query/provisioning, cross-knowledge analysis, analyzers, briefings, digests, timelines, networks, knowledge gaps, relationship health, follow-up status, finding explanations, planning/decision, simulation, comparison, planning explanation, extraction, the proposal lifecycle, and informational runtime notifications.

`extract_source`, `create_proposal`, `kg.captures.propose`, and `kg.planning.create_proposal` may persist review artifacts but never execute an Intent. `submit_proposal` is the only canonical-write capability; centralized policy requires `proposal:submit` and a fingerprint-matching approval receipt, and the existing `ProposalSubmitter` and Engine enforce the same immutable approval again. Planning responses require `planning:read`; restricted graph or Capture evidence is removed before read output unless the agent has the corresponding permission.

`kg.orchestration.notify` has the additive `operational_write` effect. It writes only Git-ignored notification runtime state, returns `executable: false`, and has no Engine dependency.

## Quick start

```sh
kg gateway capabilities
kg gateway execute kg.entities.search '{"query":"Ada"}'
kg gateway policy check kg.proposals.submit \
  '{"proposal_id":"proposal_<ULID>","dry_run":true}'
```

Ruby integration:

```ruby
gateway = AgentPlatform.build(
  vault_root: Dir.pwd,
  run_id: "run_<26-character-ULID>"
)
agent = AgentPlatform::AgentIdentity.new(
  id: "hermes:local",
  permissions: %w[graph:read intelligence:read proposal:create]
)
manifest = gateway.discover(agent: agent).find do |item|
  item.fetch("capability_id") == "kg.entities.search"
end
request = gateway.issue_request(
  invocation_token: manifest.fetch("invocation_token"),
  arguments: { query: "Ada" }
)
response = gateway.execute(request: request, agent: agent)
```

## Security boundary

- Discovery omits unavailable capabilities.
- Restricted entities require `graph:restricted`; private contact points require `graph:private`.
- Output rejects storage paths, raw Markdown, handler names, Vault roots, and implementation references.
- Telemetry records identifiers, decisions, status, duration, and error codes—not arguments or graph payloads.
- Imported source text is hostile data. The deterministic extraction provider receives it as data; embedded instructions are never executed.
- No external extraction provider is enabled through the core manifests.

## Verification

```sh
ruby -I"lib" -I"test" \
  -e 'Dir["test/**/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
ruby test/validator_test.rb
ruby "validators/personal_crm/validate_vault.rb"
```

The Phase 7 suite includes Gateway, manifest, policy, session, adapter, plugin, job, golden-scenario, compatibility, security, regression, and scale tests.
