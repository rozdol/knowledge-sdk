<%*
const action = await tp.system.prompt("Promised action");
const promisor = await tp.system.prompt("Promisor full wiki link");
const recipient = await tp.system.prompt("Recipient full wiki link");
const madeOn = await tp.system.prompt("Made on (YYYY-MM-DD)", tp.date.now("YYYY-MM-DD"));
const sensitivity = await tp.system.suggester(["private", "normal", "restricted"], ["private", "normal", "restricted"]);
const origin = await tp.system.suggester(["given_by_subject", "public", "third_party", "inferred", "mixed"], ["given_by_subject", "public", "third_party", "inferred", "mixed"]);
const id = tp.user.new_id("commitment");
const now = tp.user.now_iso();
const title = `${madeOn} - ${action}`;
await tp.file.move(tp.user.unique_path("Commitments/Promises", tp.user.safe_filename(title), id));
-%>
---
id: <% id %>
type: commitment
schema_version: 1
name: <% tp.user.yaml_quote(action) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/commitment
  - commitment/promise
commitment_kind: promise
promisor: <% tp.user.yaml_quote(promisor) %>
promise_to: <% tp.user.yaml_quote(recipient) %>
action: <% tp.user.yaml_quote(action) %>
commitment_status: open
made_on: <% madeOn %>
sensitivity: <% sensitivity %>
data_origin: <% origin %>
---
# <% action %>

## Notes
