# Intent Planning Guide

The planner constructs existing immutable `KnowledgeGraph::Intent` objects; there is no parallel executable command model.

| Fact | Engine Intent | Conservative rule |
|---|---|---|
| new entity mention | `CreateEntity` | only supported types with required evidence-backed defaults |
| safe scalar attribute | `UpdateEntity` | closed per-entity attribute allowlist |
| asserted relationship | `AddRelationship` | registered predicate and resolvable/planned endpoints |
| meeting | `CreateMeeting` | exact time and canonical participant links |
| interaction | `RecordInteraction` | required occurrence attributes |
| promise | `RecordPromise` | blocked until structural roles are explicit |
| follow-up | `CreateEntity(type: follow-up)` | canonical Self required |

Corrections, removals, replacements, merges, splits, renames, identity overwrites, and unsupported attributes are not inferred into executable changes. They stay rejected/blocked review items.

New entities receive deterministic proposal IDs so dependent relationships can use Engine-compatible endpoint IDs. Dependencies are explicit and cycle-checked; array order is not semantic. Planned Intent provenance carries an idempotency key derived from immutable payload and evidence.
