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

- `ReplaceMedicationSchedule(medication:, schedule:, effective_on:, dose: nil, unit: nil, schedule_details: nil, source:, observation_id:, proposal_id: nil)` replaces the active SQLite schedule row for one medication. `schedule_details` preserves optional per-time-slot conditions and administration routes for compound schedules.
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
- `UpgradeDatasetSchema(dataset:, from_version:, schema:, added_columns:, source:, proposal_id: nil)` applies an additive definition only if the current version still equals `from_version`.

The proposal dependency graph executes either lifecycle Intent before the original Dataset row. New columns must be optional. Removal, reorder, rename, retype, and constraint changes are invalid. Lifecycle results include Dataset ID, schema version, and Dataset activity ID.

## Results and errors

`execute` returns an immutable `Result` with `intent_type`, `entity_ids`, `changed_paths`, optional `value`, `replayed`, `duration_ms`, and `audit_id`. Dataset results use `value` for the SQLite row/activity references and do not report a graph content path.

Expected error families include `InvalidIntent`, `ApprovalRequired`, `EntityNotFound`, `IdentityConflict`, `RelationshipConflict`, `ValidationError`, `TransactionError`, and `AuditError`. A raised error means the graph transaction did not partially apply; consult the audit event for its rollback status.

## Hooks

Subscribe with `engine.on(:before_execute) { |context| ... }`. Supported events are `before_execute`, `after_execute`, `before_commit`, `after_commit`, `before_rollback`, and `after_rollback`. Before-commit hook failures trigger rollback. After-commit hooks must be observational because the graph is already committed.
