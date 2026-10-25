# Gateway Guide

## Public lifecycle

1. Construct an `AgentIdentity` with explicit permissions.
2. Call `Gateway#discover`. The result is already filtered by handler availability and centralized policy.
3. Select a returned manifest and retain its `invocation_token`.
4. Call `Gateway#issue_request`; this creates immutable request, trace, and timestamp fields.
5. Call `Gateway#execute` with the typed request and same identity.

`Gateway#execute` does not accept `capability: "search_entities"`. An ID or tool name used at a transport boundary is resolved by that adapter against discovery; only the opaque token reaches execution.

## Execution order

The Gateway resolves the token to the exact manifest digest and version, loads the owned session, validates arguments, evaluates policy, resolves the private handler binding, enforces the manifest timeout, validates the typed output, applies the implementation-leak guard, emits sanitized telemetry, and returns `AgentResponse`.

Request-scoped services memoize a GraphReader, immutable GraphSnapshot, feature engine, proposal store, and analyzer results only for one execution. Graph mutations are never cached.

Read-only hosts may pass `dataset_engine_factory:` and `read_only_services: true`
to `AgentPlatform.build`, plus an optional bounded `jobs:` manager. The factory
returns a `StructuredDataset::Reader`; writer/proposal service construction then
fails closed. Existing callers retain the original lazy writer services by default.
The environment policy and explicit identity capability/permission allow-lists are
still required; service injection is an additional read-safety boundary.

Entity search filters visibility before applying its limit and uses immutable-ID
ordering. Email, phone and external-ID-only matches require `graph:private`;
private identity signals do not influence an unprivileged result. Existing request
and response schemas remain unchanged.

## Response model

Every response includes `status`, `payload`, `warnings`, `errors`, `evidence`, `execution_time_ms`, `capability_id`, `capability_version`, `request_id`, and `trace_id`. Reasoning contracts additionally require `why`; handlers provide confidence and graph paths where applicable.

Errors use stable codes such as `CapabilityNotFound`, `PolicyDenied`, `ApprovalRequired`, `InvalidArguments`, `SessionExpired`, `ProposalNotFound`, `ExecutionFailed`, `Timeout`, and `UnsupportedCapability`. `execute` converts typed failures into a response. `execute!` is available for callers that prefer exceptions.

## Asynchronous execution

An asynchronous manifest returns `status: accepted` and a `job_id`. Read it with `Gateway#job_status`; only the owning agent may access the job. Job results remain in bounded process memory. Restarting a process may discard them, which is intentional: jobs are operational state and never a database or source of truth.

## Trace inspection

`Gateway#explain_trace` returns only sanitized telemetry events owned by the requesting agent. `telemetry:read_all` permits administrative cross-agent inspection. Arguments, source text, entity payloads, Markdown, and filesystem paths are never recorded.
