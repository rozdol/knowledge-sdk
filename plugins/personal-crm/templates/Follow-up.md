<%*
const action = await tp.system.prompt("Follow-up action");
const owner = await tp.system.prompt("Owner full Person wiki link");
const due = await tp.system.prompt("Due on (YYYY-MM-DD, optional)");
const sensitivity = await tp.system.suggester(["private", "normal", "restricted"], ["private", "normal", "restricted"]);
const origin = await tp.system.suggester(["given_by_subject", "public", "third_party", "inferred", "mixed"], ["given_by_subject", "public", "third_party", "inferred", "mixed"]);
const id = tp.user.new_id("followup");
const now = tp.user.now_iso();
const title = `${due || "No date"} - ${action}`;
const dueLine = due ? `due_on: ${due}` : "";
await tp.file.move(tp.user.unique_path("Commitments/Follow-ups", tp.user.safe_filename(title), id));
-%>
---
id: <% id %>
type: follow-up
schema_version: 1
name: <% tp.user.yaml_quote(action) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/follow-up
owner: <% tp.user.yaml_quote(owner) %>
action: <% tp.user.yaml_quote(action) %>
followup_status: open
<% dueLine %>
priority: normal
sensitivity: <% sensitivity %>
data_origin: <% origin %>
---
# <% action %>

## Notes
