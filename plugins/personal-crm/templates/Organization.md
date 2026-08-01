<%*
const name = await tp.system.prompt("Organization name");
const id = tp.user.new_id("org");
const now = tp.user.now_iso();
const kind = await tp.system.suggester(["company", "nonprofit", "government", "university", "fund", "community", "informal"], ["company", "nonprofit", "government", "university", "fund", "community", "informal"]);
await tp.file.move(tp.user.unique_path("Organizations", tp.user.safe_filename(name), id));
-%>
---
id: <% id %>
type: organization
schema_version: 1
name: <% tp.user.yaml_quote(name) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/organization
org_kind: <% kind %>
---
# <% name %>

## Notes
