---
schema_key: dataset
id_prefix: dataset
folder_prefixes:
  - Datasets/
required_tags:
  - entity/dataset
required_fields:
  - dataset_slug
  - dataset_kind
  - storage_backend
  - storage_table
  - purpose
  - sensitivity
  - data_origin
name_required: true
id_filename: false
---
# Dataset schema

Semantic registry entry for a structured dataset whose rows are stored by the Structured Dataset Engine.
