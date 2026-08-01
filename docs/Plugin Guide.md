# Plugin Guide

Plugins extend the SDK without changing core dispatch and without silently rewriting Vaults. A distribution plugin may contribute schemas, predicate definitions, templates, views, dataset adapters, planners, analyzers, validators, and public Gateway manifests.

```text
plugins/example/
  plugin.yml
  schemas/
  relationship_types/
  templates/
  views/
```

`plugin.yml` contains declarative paths. The SDK never executes Ruby paths supplied by a Vault or by ingested content. Trusted code plugins are installed with the SDK and register handlers explicitly through the existing `AgentPlatform::PluginRegistrar` boundary.

`kg plugin list` discovers installed SDK plugins. `kg --vault PATH plugin install NAME` is explicit and fail-closed: it refuses to replace an existing Vault file. `kg attach` may record or auto-detect a compatible profile, but attachment itself never installs plugin assets.

The bundled `personal-crm` plugin packages the current ontology, templates, views, and validator as an optional profile. Other Vaults may stay generic or use independently developed profiles; they do not need to copy this folder layout.
