# Hermes Integration Guide

Hermes integrates only through `AgentPlatform::Adapters::Hermes`. It must not import the Engine, Repository, GraphSnapshot internals, validators, Markdown documents, YAML writer, or Vault directory layout.

## Bootstrap

```ruby
gateway = AgentPlatform.build(
  vault_root: vault_root,
  run_id: run_id,
  actor_id: "hermes:local"
)
hermes = AgentPlatform::Adapters::Hermes.new(gateway)
identity = AgentPlatform::AgentIdentity.new(
  id: "hermes:local",
  permissions: %w[graph:read intelligence:read proposal:create proposal:read]
)
```

## Discovery and invocation

Call `hermes.capabilities(agent: identity, session_id: session_id)` when a conversation begins and whenever a token becomes stale. Present only returned manifests to the model. Select a manifest, validate/build arguments from `input_schema`, and pass its opaque `invocation_token` to `hermes.execute`.

Hermes must not invent an unavailable capability, reuse a token from another deployment, or infer a private handler name from the display `name`. A token is valid only for the exact registered manifest digest and version.

Write-oriented behavior ends at proposals. Hermes may extract sources and create proposals with `proposal:create`. It may inspect proposals with `proposal:read`. Do not grant `proposal:submit` unless Hermes is explicitly operating in a trusted local role; even then, exact external human approval is mandatory and checked twice.

## Long operations

An asynchronous response contains `status: accepted` and `job_id`. Poll or wait through `hermes.job`. Do not treat a queued job as a completed answer.

## Reasoning display

Render `why`, `evidence`, `confidence`, and `graph_path` for reasoning capabilities. Evidence contains safe immutable record references rather than Markdown paths or raw note bodies. Preserve warnings and typed errors instead of converting them into unsupported claims.
