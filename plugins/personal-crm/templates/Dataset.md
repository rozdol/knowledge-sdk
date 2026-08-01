<%*
const name = await tp.system.prompt("Dataset name");
const slug = await tp.system.prompt("Safe lowercase dataset slug");
const kind = await tp.system.prompt("Dataset kind", slug);
const purpose = await tp.system.prompt("Purpose");
const id = tp.user.new_id("dataset");
const now = tp.user.now_iso();
await tp.file.move(tp.user.unique_path("Datasets", tp.user.safe_filename(name), id));
-%>
---
id: <% id %>
type: dataset
schema_version: 1
name: <% tp.user.yaml_quote(name) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/dataset
dataset_slug: <% tp.user.yaml_quote(slug) %>
dataset_kind: <% tp.user.yaml_quote(kind) %>
storage_backend: sqlite
storage_table: <% tp.user.yaml_quote(slug) %>
purpose: <% tp.user.yaml_quote(purpose) %>
sensitivity: private
data_origin: given_by_subject
---
# <% name %>
