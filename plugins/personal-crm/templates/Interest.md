<%*
const name = await tp.system.prompt("Approved interest name");
const kind = await tp.system.suggester(["activity", "topic", "cuisine", "genre", "cause", "sport", "other"], ["activity", "topic", "cuisine", "genre", "cause", "sport", "other"]);
const id = tp.user.new_id("interest");
const now = tp.user.now_iso();
await tp.file.move(tp.user.unique_path("Concepts/Interests", tp.user.safe_filename(name), id));
-%>
---
id: <% id %>
type: interest
schema_version: 1
name: <% tp.user.yaml_quote(name) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/interest
interest_kind: <% kind %>
---
# <% name %>
