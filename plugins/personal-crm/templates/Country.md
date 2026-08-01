<%*
const name = await tp.system.prompt("Country name");
const alpha2 = await tp.system.prompt("ISO alpha-2 code");
const id = tp.user.new_id("country");
const now = tp.user.now_iso();
await tp.file.move(tp.user.unique_path("Places/Countries", tp.user.safe_filename(name), id));
-%>
---
id: <% id %>
type: country
schema_version: 1
name: <% tp.user.yaml_quote(name) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/country
iso_alpha2: <% alpha2.toUpperCase() %>
---
# <% name %>
