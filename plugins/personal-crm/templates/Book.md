<%*
const name = await tp.system.prompt("Book title");
const authorText = await tp.system.prompt("Authors as full Person wiki links, comma separated");
const authors = authorText.split(",").map(v => v.trim()).filter(Boolean);
const authorsYaml = authors.length ? authors.map(link => `  - ${tp.user.yaml_quote(link)}`).join("\n") : "  []";
const id = tp.user.new_id("book");
const now = tp.user.now_iso();
await tp.file.move(tp.user.unique_path("Knowledge/Books", tp.user.safe_filename(name), id));
-%>
---
id: <% id %>
type: book
schema_version: 1
name: <% tp.user.yaml_quote(name) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/book
authors:
<% authorsYaml %>
---
# <% name %>

## Notes

## Highlights
