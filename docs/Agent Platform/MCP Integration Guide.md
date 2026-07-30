# MCP Integration Guide

`AgentPlatform::Adapters::MCP` derives MCP tool definitions from policy-filtered Capability Manifests. MCP contains no graph, extraction, intelligence, proposal, or approval business logic.

`tools(agent:, session_id:)` maps each manifest to one tool with description, input/output schemas, read-only and idempotency hints, plus metadata containing the capability ID, version, manifest digest, and opaque invocation token. The MCP tool name is a transport-safe projection such as `kg_entities_search__v1`; it is not a Gateway dispatch key.

`call_tool` regenerates policy-filtered tools, finds the requested transport name, and invokes its token. A tool not present in current discovery raises `CapabilityNotFound`. This prevents a client from reaching hidden capabilities by guessing a string.

```ruby
mcp = AgentPlatform::Adapters::MCP.new(gateway)
tools = mcp.tools(agent: identity)
result = mcp.call_tool(
  name: "kg_entities_search__v1",
  arguments: { "query" => "Ada" },
  agent: identity
)
```

The result uses MCP `content`, `structuredContent`, and `isError`. `structuredContent` is the same typed Agent Response available to Hermes and CLI. An MCP host should refresh tools when permissions, feature flags, session, deployment, or manifests change.

No MCP transport server or network listener is started by Phase 7. The adapter is the protocol mapping used by a hosting process; network authentication, TLS, and process lifecycle belong to that host.
