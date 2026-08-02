# Structured Dataset Engine

Version 15 adds immutable Dataset Templates and autonomous provisioning to the device-local SQLite backend while preserving the Knowledge Graph as the semantic system of record. Dataset routing classifies structured observations before the Knowledge Graph extraction pipeline; template selection recognizes structured files and extracted evidence before asking the user for any Dataset or schema choice.

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

Conversational callers never need to run `kg dataset create`. If a classified observation targets a missing Dataset, `AutonomousRegistry` adds an immutable `CreateDataset` prerequisite to the same review proposal. Exact approval and dependency-ordered submission create the Dataset, then execute the original row Intent. No Dataset is created while classifying or proposing.

## Dataset Template Registry

Templates are immutable, semantic-versioned objects registered by trusted SDK plugins. Each template declares the complete Dataset definition, column constraints and units, parser, recommended analyzers, default visualizations, privacy level, review-only recommendation rules, and future adapters. The built-in catalogue is:

- Health: Blood Tests, Medication Schedules, Blood Pressure, Weight, Heart Rate, Sleep, Exercise, Nutrition.
- Finance: Expenses, Income, Subscriptions.
- Trading: Trades, Positions, Equity Curve.
- CRM: Contacts, Meetings, Interactions.
- Generic: Key/Value Measurements, Custom Observation Log.

Selection returns `template`, `template_version`, `confidence`, and `reason`. PDF/OCR text, image OCR, CSV, extracted Excel tables, email, transcripts, and ordinary text all use the same selection interface. Imported content is hostile data: it may be parsed by an installed template but can never register a template or executable rule.

```text
Evidence -> Intent Classifier -> Template Registry -> CreateDatasetProposal
  -> exact approval -> Dataset -> approved row retry -> SQLite -> Activity -> kg analyze
```

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
evidence_id, source_uri, source_filename, source_page, source_span
```

SQLite foreign keys, WAL journaling, busy timeouts, transactions, unique indexes, requested indexes, type checks, JSON validity checks, ranges, and enumerations are enabled. Ruby-side validation adds ISO dates/timestamps, regular-expression constraints, and consistent coercion.

Supported column types are `TEXT`, `INTEGER`, `REAL`, `BOOLEAN`, `DATE`, `DATETIME`, and `JSON`.

Medication schedules use required JSON `schedule_json`, immutable `schedule_id`, and inclusive
`effective_from`/`effective_until` intervals. `medication` is indexed and is not unique, so multiple
same-medication time slots or doses are valid. The generic recurrence contract is published in
`schedule.schema.json`; medication-specific dose, route, reason, provider, and notes remain separate
columns. SQLite implicit rowids are never selected or exposed.

## Commands

```sh
kg dataset create blood_tests # trusted administrative compatibility command
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

Smart imports are proposal-driven rather than direct bulk writes. The selected template parses bounded rows and source spans, one immutable `InsertDatasetRow` Intent is created per row, and every row depends on the lifecycle prerequisite. This gives submission deterministic retry and per-measurement provenance. The complete normalized source rendition is stored under `.knowledge/evidence/sources/`; `source_uri` retains the original artifact location supplied by Hermes or another adapter.

### Normalized blood tests

Blood tests never add one column per biomarker. Arbitrary reports use rows with `test_date`, `panel`, `analyte`, `value`, `unit`, `reference_low`, `reference_high`, `reference_text`, `flag`, `specimen`, `laboratory`, and `comments`. `observed_at` and `marker` are compatibility aliases for previously approved Phase 13/14 Intents and queries. Analyte names remain data and are not hardcoded by the parser.

## Schema migration

The database has an engine-level `PRAGMA user_version` and an independent version history for each dataset. Dataset upgrades may append optional columns only. Existing columns cannot be removed, reordered, renamed, retyped, or have constraints changed. Required added columns are rejected because they would invalidate existing rows.

The exact legacy medication schedule shape is the only bounded exception. An approved
`UpgradeDatasetSchema(migration_id: "medication_schedules_v2")` performs a trusted SDK-owned
copy-and-verify rebuild in one transaction, preserves logical row and provenance IDs, verifies the
row count, records schema/activity history, and rejects any target other than the SDK schema.

For proposal-driven rows, unknown columns generate `DatasetSchemaUpgradeProposal` metadata and an immutable `UpgradeDatasetSchema` prerequisite. The Intent records the observed `from_version`, complete additive replacement definition, and added columns. Execution rechecks the version, performs the approved migration through the Dataset lifecycle handler, records `migrate` activity, and only then retries the original row dependency.

## Platform integration

- Observation: deterministic classification proposes a named Dataset Intent (or the compatibility `InsertDatasetRow`) before graph extraction. The proposal preserves exact evidence and confidence, requires human review, and writes the row only after immutable approval. The immutable Intent ID is stored with the row, so resubmitting or replaying the approved proposal returns the original row instead of duplicating it.
- Routing: `KnowledgeSDK::IntentClassifier` detects `health`, `finance`, `crm`, `trading`, `knowledge`, or `generic`, then selects the highest-confidence plugin result for the winning domain. Named medication Intents cover create, replace, pause, resume, stop, dose evolution, and recurrence evolution; measurement and finance Intents remain unchanged. Generic analysis/planning/search plugins run only if the domain plugins do not match, and `graph.observe` is the final fallback. Dataset proposals use the existing proposal, approval, submission, Engine, Event Bus, and Activity components.
- Search/Hermes: `kg.datasets.query` answers supported latest-value and trend questions, then falls back to graph query/search.
- Planning: a read-only adapter computes neutral dataset signals such as numeric change, missed-dose counts, and recurring expense candidates. Signals appear in the planning trace; SQLite performs no interpretation.
- Activity: every dataset change is recorded in `sde_activity`, publishes `DatasetChanged`, and appears in Knowledge Activity with the Dataset registry object and row/event reference.
- Privacy: raw measurements and financial values stay in SQLite. Canonical Dataset notes contain metadata, never row values. Restricted datasets are redacted from activity and excluded from ordinary conversational/planning reads.
- Analysis: `kg analyze` coordinates graph evidence, Dataset rows/statistics, Activity, Intelligence, planning signals, events, and cache through deterministic analysis plugins. Correlations always report aligned windows, confidence, and `causal: false`.

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
kg chat --text "Today's blood pressure was 128 over 81" --json --explain
route: dataset -> InsertBloodPressureMeasurement -> review-only Proposal
  -> explicit approval -> existing Engine -> SQLite row -> DatasetChanged -> Knowledge Activity
```

English, Russian, and Greek recurring medication statements use bounded deterministic normalization
and morphology patterns. Compound input may create several immutable schedule Intents in one review
proposal, including several rows for the same medication. `kg chat --explain` reports the parsed
schedule, Schedule object, effective interval, and generated Intent types. Past-tense administration
events do not become schedules: until a named medication-log Intent is installed, they return
structured clarification and never fall through to graph observation.

`kg observe` uses the same classifier, so recognized structured observations take this Dataset path as well. Ambiguous CSV or Markdown tables request a Dataset schema; they are never sent to graph extraction. Individual measurements, medication schedules, and financial rows never appear in Dataset registry Markdown.

Machine-readable contracts are in `dataset-definition.schema.json`, `dataset-template.schema.json`, `dataset-row.schema.json`,
`schedule.schema.json`, and `response.schema.json` in this directory.
Dataset evolution and analysis contracts are in `docs/Dataset Intelligence/`.
