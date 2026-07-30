# Plugin Guide

Plugins extend the platform without changing Gateway dispatch code. A trusted host supplies two separate artifacts:

1. one or more public Capability Manifest JSON files;
2. explicit in-process handler callables keyed by capability ID and version.

`PluginRegistrar` validates and registers both. It never auto-requires Ruby referenced by a manifest, because public manifests are data and may not become code-loading instructions.

```ruby
registrar = AgentPlatform::PluginRegistrar.new(
  registry: registry,
  handlers: handlers
)
registrar.load_manifests(
  plugin_manifest_directory,
  handlers: {
    ["plugin.crm.score", "1.0.0"] => score_handler
  }
)
```

A plugin handler receives validated arguments and `ExecutionContext`. It should call existing platform services, return `HandlerResult`, avoid global caches, and never parse or write canonical Markdown. Canonical writes must remain proposal submission through the Engine.

Every plugin should include manifest-validation tests, handler tests, policy/discovery tests, transport-schema tests, compatibility tests against its previous supported version, leak-guard tests, timeouts, and golden examples. Fixtures must be synthetic and must not contain private real data.

Capability IDs should use a stable reverse-domain or plugin namespace. A new incompatible contract receives a major version. Do not silently reuse an ID/version for changed behavior: its manifest digest and token will change, but clients also need an explicit compatibility signal.
