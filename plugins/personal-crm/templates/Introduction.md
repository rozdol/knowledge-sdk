<%*
const introducer = await tp.system.prompt("Introducer full wiki link");
const introducerId = await tp.system.prompt("Introducer person ID");
let first = await tp.system.prompt("First introduced person full wiki link");
let firstId = await tp.system.prompt("First introduced person ID");
let second = await tp.system.prompt("Second introduced person full wiki link");
let secondId = await tp.system.prompt("Second introduced person ID");
if (firstId > secondId) { [first, second] = [second, first]; [firstId, secondId] = [secondId, firstId]; }
const occurred = await tp.system.prompt("Occurred on (YYYY, YYYY-MM, or YYYY-MM-DD)");
const sensitivity = await tp.system.suggester(["private", "normal", "restricted"], ["private", "normal", "restricted"]);
const origin = await tp.system.suggester(["given_by_subject", "public", "third_party", "inferred", "mixed"], ["given_by_subject", "public", "third_party", "inferred", "mixed"]);
const id = tp.user.new_id("introduction");
const now = tp.user.now_iso();
await tp.file.move(`Interactions/Introductions/${id}`);
-%>
---
id: <% id %>
type: introduction
schema_version: 1
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/introduction
introducer: <% tp.user.yaml_quote(introducer) %>
introducer_id: <% introducerId %>
person_a: <% tp.user.yaml_quote(first) %>
person_a_id: <% firstId %>
person_b: <% tp.user.yaml_quote(second) %>
person_b_id: <% secondId %>
assertion_status: asserted
confidence: confirmed
asserted_by: human
asserted_at: <% now %>
sensitivity: <% sensitivity %>
data_origin: <% origin %>
occurred_on: <% tp.user.yaml_quote(occurred) %>
---
