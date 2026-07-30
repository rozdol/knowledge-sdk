# Capability Registry Guide

## Canonical contract

Capability Manifests under `config/agent_platform/manifests/` are the canonical public contracts. A manifest declares:

- `manifest_schema_version`, stable `capability_id`, display `name`, and semantic `version`;
- description, JSON input/output schemas, typed errors, and examples;
- synchronous or asynchronous execution, effects, timeout, and idempotency;
- permissions, risk, approval policy, and proposal-ID argument where relevant;
- explanation requirement, supported transports, and deprecation metadata.

Manifests never contain handler constants, Ruby class names, Vault paths, storage configuration, or other implementation bindings.

## Registration

`ManifestLoader` reads JSON objects or arrays from one or more files. `CapabilityRegistry` rejects malformed manifests, duplicate ID/version pairs, invalid semantic versions, and token collisions. `HandlerRegistry` is separate and private. A capability becomes discoverable only when both its manifest and exact-version handler are present.

Opaque invocation tokens are derived from capability ID, semantic version, and the full manifest digest. Editing a manifest produces a new token; stale callers must rediscover rather than silently executing a changed contract.

## Versioning

Use semantic versions. Patch versions clarify behavior without schema changes. Minor versions may add optional inputs or outputs. Removing outputs or adding required inputs requires a major version. `ManifestCompatibility.validate!` enforces these principal compatibility gates, while contract tests should cover domain-specific behavior.

Never silently replace old behavior. Multiple versions may coexist in the Registry. A caller that omits a version at a local selector receives the highest registered version; an issued token always names one exact contract.

## Adding a capability

1. Add a manifest JSON file; do not edit Gateway dispatch code.
2. Implement a handler over existing public platform services.
3. Register the handler in the trusted handler catalog or plugin registrar.
4. Add input, output, error, policy, security, adapter, and compatibility tests.
5. Confirm discovery exposes it only to the intended identities.
6. Regenerate documentation or an SDK through `AgentPlatform::Generators` if desired.

The manifest is authoritative for public behavior. The handler may be replaced without changing clients when the same observable contract remains valid.
