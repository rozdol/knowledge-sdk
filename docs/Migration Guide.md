# Migration Guide

Phase 12 extracts executable code from an existing Obsidian Vault into the standalone `knowledge-sdk` repository. The original Vault keeps its own name and repository; it is not converted into a product called `knowledge-vault`.

## Existing Vault migration

1. Commit or back up the Vault and ensure only one writer is active.
2. Install or run the standalone SDK.
3. Validate the still-embedded Vault with `kg --vault /path/to/vault validate`.
4. Attach it with `kg attach /path/to/vault`. Attachment does not modify it.
5. Run `kg --vault /path/to/vault migrate --prune-embedded-sdk`.
6. Run `kg --vault /path/to/vault doctor` and the Vault validator again.
7. Review and commit the Vault deletion of embedded product code separately from SDK development history.

The migration moves legacy `_System/KnowledgeGraph/Runtime/` data to `.knowledge/runtime/`, with the Dataset database moved to `.knowledge/datasets.sqlite3`. It then moves `_System/KnowledgeGraph/`, `_System/Tools/`, and `_System/Acceptance Testing/` into an external backup under the SDK configuration directory. Markdown notes, `_System/Schema`, `_System/Relationship Types`, templates, views, `.obsidian`, attachments, and user data stay in place.

The result is a normal Obsidian Vault containing knowledge and user-selected ontology/configuration, not a subordinate SDK project.

## Rollback

`kg migrate` reports the exact external backup path. Before further changes, restore embedded tooling with:

```sh
kg --vault /path/to/vault migrate --rollback /path/from/migration/output
```

Rollback refuses to replace paths that already exist. Runtime location changes are deterministic and should be reversed only before either location receives newer writes; keep the pre-migration Git checkpoint as the authoritative full-batch rollback.

## Caller migration

Replace source-relative invocations such as `ruby _System/KnowledgeGraph/bin/kg` with the installed `kg` executable and either attach/select a Vault or pass `--vault PATH`. Replace `require_relative` with `require "knowledge_sdk"` and `require "knowledge_graph"`.

`KnowledgeGraph::Engine.new(vault_root: ...)` remains supported. New callers may use `KnowledgeSDK.engine(vault: ...)` and `KnowledgeSDK::VaultLocator`.

## Compatibility

Canonical filenames, immutable IDs, frontmatter, bodies, wiki links, Dataview views, ontology records, and Intent contracts are unchanged. The intentional incompatibilities are the removal of embedded executable paths and the Runtime relocation. The migration command handles Runtime relocation; installed `kg` replaces the embedded launcher.

## Version 15 Dataset migration

Opening an existing Dataset database with version 15 performs an additive engine migration to SQLite `user_version = 3`. It appends nullable Evidence locator columns (`evidence_id`, `source_uri`, `source_filename`, `source_page`, and `source_span`) to each physical Dataset table and creates a partial Evidence ID index. Existing rows, Dataset schema versions, Activity, proposals, approvals, and graph registry notes are unchanged.

Existing Dataset notes without template metadata remain valid. New automatically provisioned notes record template ID, semantic version, and digest. Existing blood-test schemas continue accepting approved `observed_at`/`marker` Intents; the first approved Phase 15 templated import may add optional normalized fields through the ordinary `UpgradeDatasetSchema` prerequisite. Destructive conversion is neither required nor performed.

## Version 16 Capture adoption

Knowledge Capture is additive and has no eager Vault migration. Existing Markdown notes, inbox
folders, bookmarks, graph entities, Evidence, and Dataset rows are not scanned, moved, or converted.
No Capture schema is installed into `_System/Schema`; the SDK validators recognize the versioned
`Captures/capture_<ULID>.md` contract directly. The directory is created only by the first approved
`CreateCapture` transaction.

Capture schema version 1 is the only accepted canonical format. A future format change must ship a
trusted, versioned SDK migration that plans immutable Intents, validates a staged candidate, preserves
body bytes and unknown compatible frontmatter, and requires review before execution. Attached-Vault
content cannot supply migration code. Rollback of a Version 16 Capture mutation uses the existing
Engine audit/receipt history and the Vault's normal backup/version-control boundary; no background
rewriter runs during `kg attach`, `kg doctor`, or `kg migrate`.
