# Migration Guide

## Existing vaults

No schema or note migration is required. The Engine reads the current schema-v1.0 notes in place and uses the existing `_System/Schema`, `_System/Relationship Types`, and `validate_vault.rb` contracts. Filenames, IDs, bodies, Dataview views, and Obsidian readability remain unchanged.

Before enabling automated writes:

1. Commit or otherwise preserve the current vault state.
2. Run `ruby "_System/Tools/validate_vault.rb"`.
3. Run `ruby "_System/KnowledgeGraph/bin/kg" doctor`.
4. Run the Engine and validator test suites.
5. Give each automation batch one `run_<ULID>` and only one active writer.

## Caller migration

Replace direct Markdown/YAML mutation with an Intent. A previous `update_person` operation becomes `UpdateEntity`; direct edge fields become `AddRelationship`; rename scripts become `RenameEntity`; duplicate cleanup becomes an approved `MergeEntities` command.

Humans may continue to use Obsidian and templates. Automated callers—including agents, CLI scripts, MCP, REST, and future UI code—must use `Engine#execute`. Thin convenience methods are acceptable only because they construct an Intent and return through that method.

## Runtime data

The first successful command creates local `_System/KnowledgeGraph/Runtime/` receipts and `audit.jsonl`. This directory is Git-ignored and is not canonical. Preserve it in a private local backup if cross-machine replay history is required. Deleting it does not delete graph facts, but removes prior idempotency receipts and audit replay history.

## Rollback

An in-process failure restores pre-write file snapshots. For a completed but unwanted command, revert the associated Git commit or issue compensating Intents; do not hand-edit canonical Markdown. A merged stub can be restored with approved `SplitEntity`, but rewritten links remain on the former survivor unless explicitly reassigned by supported Intents.
