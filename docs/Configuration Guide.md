# Configuration Guide

The default configuration is `~/.knowledge-sdk/config.yml`. Set `KG_CONFIG` or pass `--config PATH` to use another file. Configuration is external to every Vault so attachment never imposes a metadata filename or internal project structure.

```yaml
version: 1
active_vault: vault_214af067bf306b5b
vaults:
  vault_214af067bf306b5b:
    id: vault_214af067bf306b5b
    name: Personal
    path: /Users/example/vaults/Personal
    profile: personal-crm
    attached_at: 2026-08-01T12:00:00Z
plugins: []
dataset_db: .knowledge/datasets.sqlite3
```

Vault IDs are deterministic hashes of canonical absolute paths. Names are display labels and need not match folder names. The optional `profile` selects SDK-owned validation and capability contracts; it does not rename or take ownership of the Vault.

Selection precedence is `--vault`, `KG_VAULT`, upward discovery, then `active_vault`. `--dataset-db`, `KG_DATASET_DB`, and `dataset_db` override the dataset location; relative paths resolve inside the active Vault. `KG_RUN_ID` and `KG_ACTOR_ID` supply audit defaults. CLI flags win over environment and configuration.

`kg detach PATH_OR_NAME` removes only the registry entry. It never removes notes, ontology, `.obsidian`, `.knowledge`, or Git history.
