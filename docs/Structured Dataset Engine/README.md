# Structured Dataset Engine

Version 11 adds a device-local SQLite backend for structured rows while preserving the Knowledge Graph as the semantic system of record.

## Architecture

```text
Hermes / kg chat
       |
Agent Gateway and safe query adapters
       |
       +-- Knowledge Graph: Dataset identity, ownership, purpose, sensitivity
       +-- Structured Dataset Engine: typed rows, indexes, row provenance
       +-- Object Store: source artifacts
```

SQLite does not contain graph relationships, plans, findings, or reasoning. Dataset query results may be consumed by search and planning adapters, but interpretation happens outside SQLite. Restricted datasets are excluded from conversational search and planning signals unless the caller has an explicit restricted-data capability.

## Dataset Registry

Each dataset is a canonical `dataset` note created through `CreateEntity`. The note contains:

- immutable `dataset_<ULID>` identity;
- `dataset_slug` and human name;
- `dataset_kind`, owner link/ID, and purpose;
- `storage_backend: sqlite` and the safe table name;
- sensitivity and data origin.

The operational SQLite catalog uses the immutable Dataset ID as its key. It retains only the physical table mapping, executable row schema, and schema history required by the storage engine. Dataset creation stages the SQLite catalog/table in a transaction while the graph Engine validates and commits the canonical registry note. A failed SQLite commit triggers an Engine-based graph compensation attempt.

## Database schema

One ignored, device-local database is stored at `.knowledge/datasets.sqlite3`.

```sql
sde_datasets(
  dataset_id PRIMARY KEY, table_name UNIQUE, schema_version,
  schema_json, created_at, updated_at
)

sde_schema_versions(
  dataset_id, version, schema_json, created_at,
  PRIMARY KEY(dataset_id, version),
  FOREIGN KEY(dataset_id) REFERENCES sde_datasets(dataset_id)
)

sde_activity(
  activity_id PRIMARY KEY, dataset_id, action, row_id, created_at,
  actor_id, source, observation_id, proposal_id, approval_id, run_id,
  FOREIGN KEY(dataset_id) REFERENCES sde_datasets(dataset_id)
)
```

Every dataset has its own physical table. User-defined columns are followed by:

```text
row_id, created_at, updated_at, created_by, source,
observation_id, proposal_id, approval_id, intent_id
```

SQLite foreign keys, WAL journaling, busy timeouts, transactions, unique indexes, requested indexes, type checks, JSON validity checks, ranges, and enumerations are enabled. Ruby-side validation adds ISO dates/timestamps, regular-expression constraints, and consistent coercion.

Supported column types are `TEXT`, `INTEGER`, `REAL`, `BOOLEAN`, `DATE`, `DATETIME`, and `JSON`.

## Commands

```sh
kg dataset create blood_tests
kg dataset list
kg dataset describe blood_tests
kg dataset insert blood_tests \
  observed_at=2026-08-01T09:00:00Z marker=Hemoglobin value=14.1 unit=g/dL \
  --source laboratory
kg dataset update blood_tests row_<ULID> value=14.2 --source correction
kg dataset delete blood_tests row_<ULID> --source correction
kg dataset query blood_tests --where "marker='Hemoglobin'" --order observed_at:desc
kg dataset export blood_tests --format csv --file blood-tests.csv
kg dataset import blood_tests --file blood-tests.xlsx
kg dataset stats blood_tests
kg dataset explain blood_tests row_<ULID>
```

Every command accepts `--json`. Custom datasets use `kg dataset create NAME --schema FILE_OR_JSON`. `kg dataset migrate DATASET --schema FILE_OR_JSON` is an additional administrative command for additive schema migrations.

The `--where` grammar permits comparisons, `LIKE`, `IS NULL`, `IS NOT NULL`, and `AND`. Column identifiers, operators, values, sort order, limits, offsets, and selected columns are validated and bound as parameters. Conversational clients receive only deterministic natural-language dataset capabilities; they cannot submit SQL or `--where` expressions.

## Import and export

CSV and JSON use Ruby standard-library parsers. XLSX uses a minimal Office Open XML reader/writer and the operating system's `zip`/`unzip` tools; it does not require an external database or spreadsheet service. Import is all-or-nothing. Exported audit columns are ignored on re-import so the destination creates fresh provenance.

## Schema migration

The database has an engine-level `PRAGMA user_version` and an independent version history for each dataset. Dataset upgrades may append optional columns only. Existing columns cannot be removed, reordered, renamed, retyped, or have constraints changed. Required added columns are rejected because they would invalidate existing rows. Destructive upgrades require a future explicit copy-and-verify migration design.

## Platform integration

- Observation: deterministic recognition can propose `InsertDatasetRow`. The proposal preserves exact evidence and confidence, requires human review, and writes the row only after immutable approval. The immutable Intent ID is stored with the row, so resubmitting or replaying the approved proposal returns the original row instead of duplicating it.
- Search/Hermes: `kg.datasets.query` answers supported latest-value and trend questions, then falls back to graph query/search.
- Planning: a read-only adapter computes neutral dataset signals such as numeric change, missed-dose counts, and recurring expense candidates. Signals appear in the planning trace; SQLite performs no interpretation.
- Activity: every dataset change is recorded in `sde_activity`, publishes `DatasetChanged`, and appears in Knowledge Activity with the Dataset registry object and row/event reference.
- Privacy: raw measurements and financial values stay in SQLite. Canonical Dataset notes contain metadata, never row values. Restricted datasets are redacted from activity and excluded from ordinary conversational/planning reads.

## Examples

```text
kg chat --text "What was my latest hemoglobin?" --json --explain
route: search -> kg.datasets.query -> newest matching blood_tests row
```

```text
kg chat --text "Show my blood pressure trend." --json --explain
route: search -> kg.datasets.query -> time-ordered blood_pressure rows
```

```text
kg observe --text "My blood pressure today was 128 over 81." --json
Proposal -> explicit approval -> InsertDatasetRow -> DatasetChanged -> Knowledge Activity
```

Machine-readable contracts are in `dataset-definition.schema.json`, `dataset-row.schema.json`, and `response.schema.json` in this directory.
