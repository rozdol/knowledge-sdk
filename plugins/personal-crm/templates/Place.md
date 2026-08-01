<%*
const name = await tp.system.prompt("Place name");
const kind = await tp.system.suggester(["venue", "office", "home", "hotel", "airport", "park", "restaurant", "cafe", "bar", "food_stall", "online", "other"], ["venue", "office", "home", "hotel", "airport", "park", "restaurant", "cafe", "bar", "food_stall", "online", "other"]);
const id = tp.user.new_id("place");
const now = tp.user.now_iso();
await tp.file.move(tp.user.unique_path("Places/Locations", tp.user.safe_filename(name), id));
-%>
---
id: <% id %>
type: place
schema_version: 1
name: <% tp.user.yaml_quote(name) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/place
place_kind: <% kind %>
---
# <% name %>

## Notes
