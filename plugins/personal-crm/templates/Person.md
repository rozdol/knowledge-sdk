<%*
const name = await tp.system.prompt("Canonical person name");
const id = tp.user.new_id("person");
const now = tp.user.now_iso();
const tier = await tp.system.suggester(["active", "inner", "dormant", "archive"], ["active", "inner", "dormant", "archive"]);
const sensitivity = await tp.system.suggester(["private", "normal", "restricted"], ["private", "normal", "restricted"]);
const origin = await tp.system.suggester(["given_by_subject", "public", "third_party", "inferred", "mixed"], ["given_by_subject", "public", "third_party", "inferred", "mixed"]);
await tp.file.move(tp.user.unique_path("People", tp.user.safe_filename(name), id));
-%>
---
id: <% id %>
type: person
schema_version: 1
name: <% tp.user.yaml_quote(name) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/person
tier: <% tier %>
sensitivity: <% sensitivity %>
data_origin: <% origin %>
contact_policy: normal
---
# <% name %>

## Relationship context

## Notes
