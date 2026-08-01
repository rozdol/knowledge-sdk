<%*
const name = await tp.system.prompt("City name");
const country = await tp.system.prompt("Country full wiki link");
const id = tp.user.new_id("city");
const now = tp.user.now_iso();
await tp.file.move(tp.user.unique_path("Places/Cities", tp.user.safe_filename(name), id));
-%>
---
id: <% id %>
type: city
schema_version: 1
name: <% tp.user.yaml_quote(name) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/city
country: <% tp.user.yaml_quote(country) %>
---
# <% name %>
