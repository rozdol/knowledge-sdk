<%*
const name = await tp.system.prompt("Approved technology name");
const kind = await tp.system.suggester(["product", "platform", "language", "framework", "protocol", "method", "other"], ["product", "platform", "language", "framework", "protocol", "method", "other"]);
const id = tp.user.new_id("technology");
const now = tp.user.now_iso();
await tp.file.move(tp.user.unique_path("Concepts/Technologies", tp.user.safe_filename(name), id));
-%>
---
id: <% id %>
type: technology
schema_version: 1
name: <% tp.user.yaml_quote(name) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/technology
technology_kind: <% kind %>
---
# <% name %>
