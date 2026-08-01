<%*
const name = await tp.system.prompt("Approved profession name");
const id = tp.user.new_id("profession");
const now = tp.user.now_iso();
await tp.file.move(tp.user.unique_path("Concepts/Professions", tp.user.safe_filename(name), id));
-%>
---
id: <% id %>
type: profession
schema_version: 1
name: <% tp.user.yaml_quote(name) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/profession
---
# <% name %>
