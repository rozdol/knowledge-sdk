<%*
const title = await tp.system.prompt("Interaction title");
const kind = await tp.system.suggester(["meeting", "call", "email", "message", "letter", "encounter", "co_attendance"], ["meeting", "call", "email", "message", "letter", "encounter", "co_attendance"]);
const folderMap = {meeting:"Meetings", call:"Calls", email:"Messages", message:"Messages", letter:"Other", encounter:"Other", co_attendance:"Other"};
const starts = await tp.system.prompt("Start (ISO 8601 with offset)", tp.user.now_iso());
const participantText = await tp.system.prompt("Participants as full wiki links, comma separated");
const participants = participantText.split(",").map(v => v.trim()).filter(Boolean);
const participantsYaml = participants.map(link => `  - ${tp.user.yaml_quote(link)}`).join("\n");
const weight = await tp.system.suggester(["substantive", "incidental", "mass"], ["substantive", "incidental", "mass"]);
const sensitivity = await tp.system.suggester(["private", "normal", "restricted"], ["private", "normal", "restricted"]);
const origin = await tp.system.suggester(["given_by_subject", "public", "third_party", "inferred", "mixed"], ["given_by_subject", "public", "third_party", "inferred", "mixed"]);
const id = tp.user.new_id("interaction");
const now = tp.user.now_iso();
const date = starts.slice(0, 10);
await tp.file.move(tp.user.unique_path(`Interactions/${folderMap[kind]}`, tp.user.safe_filename(`${date} - ${title}`), id));
-%>
---
id: <% id %>
type: interaction
schema_version: 1
name: <% tp.user.yaml_quote(title) %>
aliases: []
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/interaction
starts_at: <% starts %>
participants:
<% participantsYaml %>
interaction_kind: <% kind %>
contact_weight: <% weight %>
sensitivity: <% sensitivity %>
data_origin: <% origin %>
---
# <% title %>

## Summary

## Notes

## Decisions

## Promises and follow-ups
