<%*
const predicates = ["knows", "friend_of", "spouse_of", "partner_of", "parent_of", "family_of", "mentor_of", "works_for", "member_of", "founded", "leads", "contributes_to", "sponsors", "advisor_to", "invested_in", "client_of", "supplier_to", "collaborates_with", "lives_in", "born_in", "headquartered_in", "has_office_in", "incorporated_in", "likes", "dislikes", "interested_in", "expert_in", "has_profession", "speaks", "visited", "attended", "recommended", "uses", "develops", "owns", "reading", "read", "wants_to_read", "met"];
const predicate = await tp.system.suggester(predicates, predicates);
const subject = await tp.system.prompt("Subject full wiki link");
let subjectId = await tp.system.prompt("Subject immutable ID");
const object = await tp.system.prompt("Object full wiki link");
let objectId = await tp.system.prompt("Object immutable ID");
let subjectLink = subject;
let objectLink = object;
const symmetric = ["knows", "friend_of", "spouse_of", "partner_of", "family_of", "collaborates_with", "met"].includes(predicate);
if (symmetric && subjectId > objectId) { [subjectId, objectId] = [objectId, subjectId]; [subjectLink, objectLink] = [objectLink, subjectLink]; }
let recipientYaml = "";
if (predicate === "recommended") {
  const recipient = await tp.system.prompt("Recommendation recipient full wiki link");
  const recipientId = await tp.system.prompt("Recommendation recipient immutable ID");
  recipientYaml = `recipient: ${tp.user.yaml_quote(recipient)}\nrecipient_id: ${recipientId}`;
}
const sensitivity = await tp.system.suggester(["private", "normal", "restricted"], ["private", "normal", "restricted"]);
const origin = await tp.system.suggester(["given_by_subject", "public", "third_party", "inferred", "mixed"], ["given_by_subject", "public", "third_party", "inferred", "mixed"]);
const id = tp.user.new_id("relationship");
const now = tp.user.now_iso();
const folder = `Relationships/${predicate}`;
if (!app.vault.getAbstractFileByPath(folder)) await app.vault.createFolder(folder);
await tp.file.move(`${folder}/${id}`);
-%>
---
id: <% id %>
type: relationship
schema_version: 1
record_status: active
created_at: <% now %>
updated_at: <% now %>
created_by: human
updated_by: human
tags:
  - entity/relationship
  - relationship/<% predicate.replaceAll("_", "-") %>
subject: <% tp.user.yaml_quote(subjectLink) %>
subject_id: <% subjectId %>
predicate: <% predicate %>
object: <% tp.user.yaml_quote(objectLink) %>
object_id: <% objectId %>
<% recipientYaml %>
relationship_status: asserted
confidence: confirmed
asserted_by: human
asserted_at: <% now %>
sensitivity: <% sensitivity %>
data_origin: <% origin %>
---
