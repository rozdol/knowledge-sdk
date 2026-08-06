# Intent API Guide

All Intents are deeply immutable keyword objects. Every Intent accepts optional `intent_id`; callers may use it as a stable external request identifier. Without one, the complete immutable payload still provides deterministic idempotency.

## Entity lifecycle

- `CreateEntity(entity_type:, attributes:, body: nil, human_approved: false)` creates any schema-v1.0 entity. New Interest, Technology, Industry, Profession, and Language records require approval.
- `UpdateEntity(entity_id:, changes:)` changes structured facts while preserving unknown fields and body content. It rejects immutable, lifecycle, derived, and name fields.
- `RenameEntity(entity_id:, new_name:)` changes display name/path, retains the former name as an alias, and rewrites verified backlinks.
- `ArchiveEntity(entity_id:)` and `RestoreEntity(entity_id:)` set lifecycle status idempotently.
- `MergeEntities(primary_id:, secondary_id:, human_approved: false)` merges identities; Person merge requires approval.
- `SplitEntity(entity_id:, attributes:, body: nil, human_approved: false)` restores a merged stub or creates an explicitly described split-off record.

## Graph capabilities

- `AddRelationship(source:, predicate:, target:, attributes: {})` resolves endpoint IDs/redirects, validates the predicate registry, and deduplicates asserted edges.
- `RemoveRelationship(relationship_id:)` retracts an edge.
- `ReplaceRelationship(relationship_id:, source:, predicate:, target:, attributes: {})` atomically retracts and replaces an edge.

Relationship attributes may include `confidence`, `sensitivity`, `data_origin`, validity/observation dates, evidence/context links, and fields registered for that predicate. Reserved endpoint and audit fields cannot be supplied. `recommended` accepts the recipient entity ID in `recipient` or `recipient_id`; the Engine writes the matching link and ID pair.

## Occurrences and commitments

- `CreateMeeting(attributes:, body: nil)` creates an Interaction with `interaction_kind: meeting` and default substantive contact weight.
- `RecordInteraction(attributes:, body: nil)` creates a typed Interaction in the appropriate folder.
- `ImportTranscript(interaction_id:, transcript:)` writes only the `transcript` agent-managed section.
- `RecordPromise(attributes:, body: nil)` creates a promise Commitment with default open status.
- `CompleteFollowUp(follow_up_id:, completed_on: nil)` completes a Follow-up.
- `AttachEvidence(entity_id:, source_links: [], source_urls: [])` unions evidence without duplicates.

## Structured Dataset rows

Dataset Intents are immutable commands executed through the same `KnowledgeGraph::Engine` receipt and audit lifecycle. Registered Dataset handlers delegate typed row persistence to the Structured Dataset Engine; they do not create graph entities for individual rows.

- `CreateMedicationSchedule(schedule_id:, medication:, schedule_json:, effective_from:, effective_until: nil, dose: nil, unit: nil, route: nil, active: true, reason: nil, prescribing_provider: nil, notes: nil, source:, observation_id:, proposal_id: nil)` appends an immutable schedule version.
- `ReplaceMedicationSchedule(medication:, schedule_id: nil, replacement_schedule_id: nil, replace_all: false, schedule_json: nil, effective_from: nil, effective_until: nil, dose: nil, unit: nil, route: nil, reason: nil, prescribing_provider: nil, notes: nil, source:, observation_id:, proposal_id: nil)` closes a targeted version and appends its successor. `replace_all: true` closes the medication's current open schedule set, which supports one future structured replacement for several daily rows. The legacy `schedule`, `effective_on`, and `schedule_details` parameters remain accepted for replay compatibility.
- `PauseMedicationSchedule(schedule_id: nil, medication: nil, paused_on:, replacement_schedule_id:, reason: nil, source:, observation_id:, proposal_id: nil)` appends an inactive interval version.
- `ResumeMedicationSchedule(schedule_id: nil, medication: nil, resumed_on:, replacement_schedule_id:, effective_until: nil, reason: nil, source:, observation_id:, proposal_id: nil)` appends an active successor.
- `StopMedication(medication:, stopped_on:, reason: nil, source:, observation_id:, proposal_id: nil)` closes active intervals for a medication without deleting rows.
- `ModifyMedicationDose(schedule_id: nil, medication: nil, replacement_schedule_id:, dose:, effective_from:, unit: nil, reason: nil, source:, observation_id:, proposal_id: nil)` versions a dose change.
- `ModifyMedicationSchedule(schedule_id: nil, medication: nil, replacement_schedule_id:, schedule_json:, effective_from:, reason: nil, source:, observation_id:, proposal_id: nil)` versions a recurrence change.
- `InsertBloodPressureMeasurement(observed_at:, systolic:, diastolic:, pulse: nil, source:, observation_id:, proposal_id: nil)` inserts a blood-pressure row.
- `InsertWeightMeasurement(observed_at:, weight_kg:, source:, observation_id:, proposal_id: nil)` inserts a weight row.
- `InsertBloodTestResult(observed_at:, marker:, value:, unit: nil, source:, observation_id:, proposal_id: nil)` inserts a laboratory row; an omitted unit is stored explicitly as `unspecified` for compatibility with existing Dataset schemas.
- `InsertBodyMeasurement(observed_at:, measurement:, value:, unit:, source:, observation_id:, proposal_id: nil)` inserts a physical-measurement row.
- `InsertExpense(occurred_on:, category:, amount:, currency:, merchant: nil, source:, observation_id:, proposal_id: nil)` inserts a financial row.
- `InsertDatasetRow(dataset:, values:, source:, observation_id:, proposal_id: nil, approval_id: nil)` remains the generic compatibility Intent for trusted Dataset adapters.

Classifier-generated Dataset Intents are always stored as review-only proposals with `human_review` approval. Submission attaches the SDK-owned Dataset handlers to the existing Engine. The Dataset activity ID is returned in `Result#value`; `DatasetChanged` and Knowledge Activity come from the existing Structured Dataset integrations.

## Dataset lifecycle

Dataset lifecycle mutations are also immutable, exact-approval-gated Intents. `AutonomousRegistry` generates them as dependencies; public conversational adapters do not execute them directly.

- `CreateDataset(dataset_id:, dataset:, schema:, owner_id: nil, source:, proposal_id: nil)` creates the canonical Dataset registry entity and its SQLite catalog/table from one approved definition.
- `UpgradeDatasetSchema(dataset:, from_version:, schema:, added_columns:, migration_id: nil, source:, proposal_id: nil)` applies an additive definition only if the current version still equals `from_version`. The sole non-additive migration ID is the trusted `medication_schedules_v2` copy-and-verify transform; unknown IDs are rejected.

The proposal dependency graph executes either lifecycle Intent before the original Dataset row. New columns must be optional. Removal, reorder, rename, retype, and constraint changes are invalid except for the exact SDK-owned medication migration described above. Lifecycle results include Dataset ID, schema version, and Dataset activity ID.

## Knowledge Capture

Capture identity and content fields are immutable. Lifecycle metadata uses separate Intents, and every
Intent executes through the same candidate validation, optimistic concurrency, receipt, audit, and
event hooks as graph operations.

- `CreateCapture(capture_id: nil, kind:, title:, body:, captured_at: nil, created_by: "agent", importance: "normal", topics: [], tags: [], language: "und", evidence: [], source: "unknown", sensitivity: "private")` creates a version-1 Capture in `status: inbox`. Conversational callers place this Intent in a proposal and normally supply a deterministic ID.
- `ReviewCapture(capture_id:)` marks an inbox Capture reviewed without changing its body.
- `LinkCapture(capture_id:, related_entities: [], related_projects: [], related_contacts: [])` records exactly approved canonical targets and marks the Capture linked. It rejects empty target sets and Project/Person type mismatches.
- `PromoteCapture(capture_id:, target_kind:, target_ids:)` records successful promotion after its target dependencies execute. It never removes or rewrites the original Capture content.
- `ArchiveCapture(capture_id:)` idempotently moves the Capture to the archived terminal lifecycle state.

The natural-language intent names are `knowledge.capture`, `knowledge.capture.link`,
`knowledge.capture.promote`, `knowledge.capture.archive`, and read-only
`knowledge.capture.search`. Search is not an Engine mutation Intent.

## Results and errors

`execute` returns an immutable `Result` with `intent_type`, `entity_ids`, `changed_paths`, optional `value`, `replayed`, `duration_ms`, and `audit_id`. Dataset results use `value` for the SQLite row/activity references and do not report a graph content path.

Expected error families include `InvalidIntent`, `ApprovalRequired`, `EntityNotFound`, `IdentityConflict`, `RelationshipConflict`, `ValidationError`, `TransactionError`, and `AuditError`. A raised error means the graph transaction did not partially apply; consult the audit event for its rollback status.

## Hooks

Subscribe with `engine.on(:before_execute) { |context| ... }`. Supported events are `before_execute`, `after_execute`, `before_commit`, `after_commit`, `before_rollback`, and `after_rollback`. Before-commit hook failures trigger rollback. After-commit hooks must be observational because the graph is already committed.
