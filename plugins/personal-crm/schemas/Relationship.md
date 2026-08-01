---
schema_key: relationship
id_prefix: relationship
folder_prefixes:
  - Relationships/
required_tags:
  - entity/relationship
required_fields:
  - subject
  - subject_id
  - predicate
  - object
  - object_id
  - relationship_status
  - confidence
  - asserted_by
  - asserted_at
  - sensitivity
  - data_origin
name_required: false
id_filename: true
---
# Relationship schema

Canonical binary semantic edge. Predicate-specific rules come from `_System/Relationship Types/`.
