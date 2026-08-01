<%*
const name = await tp.system.prompt("Project name");
const status = await tp.system.suggester(["idea", "planned", "active", "paused", "completed", "cancelled"], ["idea", "planned", "active", "paused", "completed", "cancelled"]);
const id = tp.user.new_id("project");
const now = tp.user.now_iso();
await tp.file.move(tp.user.unique_path("Work/Projects", tp.user.safe_filename(name), id));
-%>
---
id: <% id %>
type: project
schema_version: 1
name: <% tp.user.yaml_quote(name) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/project
project_status: <% status %>
---
# <% name %>

## Goal

## Notes
