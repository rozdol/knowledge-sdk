<%*
const name = await tp.system.prompt("Event name");
const starts = await tp.system.prompt("Start (ISO date or instant)", tp.date.now("YYYY-MM-DD"));
const kind = await tp.system.suggester(["conference", "social", "meal", "workshop", "ceremony", "launch", "trip", "online", "other"], ["conference", "social", "meal", "workshop", "ceremony", "launch", "trip", "online", "other"]);
const id = tp.user.new_id("event");
const now = tp.user.now_iso();
await tp.file.move(tp.user.unique_path("Interactions/Events", tp.user.safe_filename(`${starts.slice(0, 10)} - ${name}`), id));
-%>
---
id: <% id %>
type: event
schema_version: 1
name: <% tp.user.yaml_quote(name) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/event
starts_at: <% starts %>
event_kind: <% kind %>
---
# <% name %>

## Notes
