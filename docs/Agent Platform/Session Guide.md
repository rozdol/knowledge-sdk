# Session Guide

Sessions are immutable, expiring process-memory context. They improve conversational continuity without becoming another database.

A session may contain a conversation ID, selected immutable entity IDs, current project/company IDs, a time window, language, active proposal ID, bounded preferences, and bounded working memory. The graph remains authoritative for entity facts.

Working memory stores only `MemoryReference` values: a small kind, immutable ID, and optional display label. It rejects copied graph records and arbitrary prose. Its default bound is 32 references and maximum configurable bound is 128; adding a new reference returns a new memory value and evicts the oldest entry when needed.

`SessionStore#create` issues an immutable session with a TTL. `update` returns and stores a new version, leaving the prior object unchanged. Fetch and update require the owning agent ID. Expired sessions are removed and raise `SessionExpired`.

```ruby
session = gateway.sessions.create(
  conversation_id: "conversation-42",
  agent_id: agent.id,
  ttl_seconds: 3600,
  selected_entity_ids: ["person_<ULID>"]
)
memory = session.working_memory.add(
  kind: "entity",
  reference_id: "person_<ULID>",
  label: "Ada"
)
gateway.sessions.update(
  session.id,
  agent_id: agent.id,
  working_memory: memory
)
```

Adapters pass `session_id` only. They do not serialize the complete session into each capability request. Session expiry never changes or deletes graph data.
