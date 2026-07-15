# Architecture

Nyanform is an Elixir/OTP proxy between an MCP client and an MCP server. It
owns the transport sessions, compiles upstream tool input schemas into a
canonical `Scroll`, and projects those schemas for a selected compatibility
profile.

This is a description of the current implementation. Two boundaries matter:

- Nyanform forwards most JSON-RPC messages semantically, but it is not a
  byte-for-byte proxy. Messages are decoded into `Protocol.Message` and encoded
  again, so whitespace, key order, and unknown top-level envelope members are
  not preserved.
- Diagnostics cover selected projection, alias, and argument-repair decisions.
  They do not record every parser or canonicalizer normalization.

The MCP specification used as the protocol reference is the official
[tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
and
[transport specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

## OTP supervision tree

`Nyanform.Application` starts `Nyanform.Supervisor` with `:one_for_one` and four
children:

| Child | Type | Current role |
|---|---|---|
| `Nyanform.Session.Registry` | unique `Registry` | Maps a session ID to its `Session.Thread`. |
| `Nyanform.Session.Supervisor` | `DynamicSupervisor` | Owns active session threads. |
| `Nyanform.Session.Manager` | `GenServer` | Serializes HTTP session creation, enforces the cap and idle expiry, and stops deleted or expired sessions. |
| `Nyanform.Compile.TaskSupervisor` | `Task.Supervisor`, maximum 32 children | Runs concurrent profile compilation used by matrix reporting. |

`Session.Thread.child_spec/1` uses `restart: :temporary`. A terminated session
is therefore removed; the dynamic supervisor does not recreate it. Other
supervised children remain isolated by the top-level `:one_for_one` strategy.

## Transport boundary

| Direction | Mode | Implementation |
|---|---|---|
| client -> Nyanform | stdio | `DownstreamStdio` reads from `IO.read(:stdio)` and writes with `IO.write`. |
| client -> Nyanform | Streamable HTTP | Bandit and Plug serve `POST`, `GET`, and `DELETE`. |
| Nyanform -> server | stdio | `UpstreamShrine` owns an Erlang port created with `:spawn_executable`. |
| Nyanform -> server | HTTP | `UpstreamShrine` uses Req. |

The downstream stdio path starts a `Session.Thread` directly. The HTTP path
goes through `Session.Manager`.

### HTTP sessions

The implemented HTTP lifecycle is:

1. A valid headerless `initialize` request creates a session. Nyanform
   generates its ID from 16 random bytes encoded as unpadded base64url.
2. Any other headerless MCP message receives HTTP 400.
3. A request carrying `mcp-session-id` must name an existing managed session.
   An unknown caller-supplied ID receives HTTP 404; it is not used to create a
   new session.
4. `POST` handles client JSON-RPC messages, `GET` returns queued upstream
   messages as an SSE response, and `DELETE` stops the session.

The manager defaults are 64 sessions, a 300,000 ms idle TTL, a 1,000 ms cleanup
interval, and a 5,000 ms stop timeout. HTTP options can override the session cap
and idle TTL for newly created sessions.

The stdio transport uses a separate internal ID made from 8 random bytes as 16
lowercase hexadecimal characters.

## JSON-RPC and MCP flow

`Protocol.Message` recognizes request, notification, response, and error
envelopes. Its fixed struct contains `jsonrpc`, `id`, `method`, `params`,
`result`, and `error`; extra top-level JSON members are discarded on re-encode.
Payload maps inside `params`, `result`, and `error.data` remain ordinary decoded
JSON values.

`Session.Thread` owns exactly one `UpstreamShrine` and handles these messages
specially:

- `initialize` validates the downstream parameters, resolves `auto` profile
  detection when requested, and returns Nyanform's capabilities with the
  protocol revision selected by the already-initialized upstream connection.
- `notifications/initialized` is forwarded and marks the downstream lifecycle
  initialized.
- `tools/list` is fetched from upstream, filtered, compiled, projected, and
  indexed in a `ToolGrimoire`.
- Downstream `tools/list` parameters, including `cursor`, are forwarded. A
  cursorless request starts a catalog sequence; cursor-bearing pages extend
  its alias map so aliases issued on earlier pages remain callable. Repeating a
  page replaces entries by original name and reuses their aliases.
- `tools/call` resolves the projected alias to the original upstream name,
  repairs arguments against the original compiled input schema, and correlates
  the upstream response to the client's request ID.

Other requests, notifications, responses, and errors are forwarded after
decode/re-encode. This is semantic forwarding, not preservation of the source
JSON bytes.

### Live tool projection and enforcement

The live `tools/list` path is:

```text
upstream tools
  -> include/exclude filters
  -> Pipeline.compile(inputSchema)
  -> Projector.project(profile, policy)
  -> name sanitization and collision handling
  -> ToolGrimoire acceptance and alias map
  -> downstream tools/list
```

`ToolGrimoire` reapplies the policy after combining projection and alias omens.
Tools with `accepted == false` are omitted from `tools/list`, except under the
`permissive` policy when the upstream tool envelope is structurally
publishable. Under `strict` and `compatible`, their aliases are absent from the
callable alias map, so calling a hidden tool returns JSON-RPC method-not-found.
Malformed catalog containers and entries without a string name or
`inputSchema` are never published, including under `permissive`.

Malformed modeled keyword values, schema children, and tool envelopes become
rejected catalog entries rather than raising out of `tools/list`; valid tools
from the same page continue through compilation and projection. A non-list
upstream `tools` value produces a controlled JSON-RPC error without terminating
the session.

The accumulated live catalog is capped by `max_tool_count`, 1024 by default.
Exceeding it returns a controlled error and retains the prior catalog state.

`tools/call` is intentionally catalog-dependent: a session must receive
`tools/list` before it can call a tool. Argument repair omens are produced by
`RewriteTalisman`, but the live session currently uses only the repaired
arguments and does not return those omens to the client.

The downstream tool definition is reconstructed with `name`, `description`,
and projected `inputSchema`, plus `outputSchema`, `annotations`, and `_meta`
when those keys existed upstream. All other tool-level fields are not
preserved.

The `passthrough` profile changes only schema projection: it returns the raw
`inputSchema` retained on the compiled root `Scroll`. Compilation, name
sanitization, policy handling, `tools/list` reconstruction, and JSON-RPC
re-encoding still occur. It is therefore not whole-message or whole-tool
byte-for-byte passthrough.

MCP tool declarations use an object-root `inputSchema` contract. Nyanform's
parser deliberately accepts additional JSON Schema root forms so it can
diagnose and project non-conforming upstreams; the `canonical` profile is a
modeled Nyanform dialect, not a metaschema conformance validator.

Before stdio shutdown on downstream EOF, Nyanform sends an upstream MCP `ping`
and drains queued upstream messages before stopping the session. With a stdio
upstream, the shared FIFO stream makes the ping response a wire-ordering
boundary and prevents a notification written before the ping response from
losing a race with EOF. A notification created after that response is outside
the boundary and can be lost during shutdown. An HTTP upstream uses separate
response/notification streams, so the same step is a best-effort drain rather
than a cross-stream ordering guarantee.

## Schema compilation boundary

`Nyanform.Schema.Pipeline.compile/2` performs four recorded operations:

1. parse, including structural validation;
2. canonicalize;
3. mark recursive local definition references;
4. calculate the deterministic digest.

Its `stages` result contains `:parse`, `:canonicalize`, `:references`, and
`:digest`, and its current `omens` result is always empty. Profile projection
and loss analysis are separate calls to `Profile.Projector`; serialization is
called internally while calculating the digest rather than reported as a
separate stage.

The `canonical` profile reconstructs normalized JSON Schema from modeled
`Scroll` fields; an `:unknown` root falls back to its retained raw schema. The
`passthrough` profile returns the retained raw root schema. See
[schema-pipeline.md](schema-pipeline.md) and
[compatibility-profiles.md](compatibility-profiles.md) for the exact boundary.

## Module map

| Module | Responsibility |
|---|---|
| `Nyanform.Schema.Scroll` | Canonical schema tree with 15 node kinds. |
| `Nyanform.Schema.Parser` | Raw JSON Schema or `Scroll` -> parsed `Scroll`; structural and depth validation. |
| `Nyanform.Schema.Canonicalizer` | Recursive normalization of child maps, `required`, definitions, and supported string formats. |
| `Nyanform.Schema.Reference` | Reference parsing plus standalone resolve and cycle-detection helpers. |
| `Nyanform.Schema.Pipeline` | The live parse/canonicalize/reference-mark/digest orchestration. |
| `Nyanform.Schema.Serializer` | Recursive metadata stripping, deterministic term serialization, and SHA-256 digest. |
| `Nyanform.Profile.Builtins` | Six built-in profile values. |
| `Nyanform.Profile.Loader` | Built-in lookup and a programmatic override helper. |
| `Nyanform.Profile.Projector` | Schema reconstruction, profile diagnostics, and policy acceptance. |
| `Nyanform.ToolGrimoire` | Per-tool compilation, projection, aliases, and live acceptance map. |
| `Nyanform.RewriteTalisman` | Schema-guided JSON-string argument repair. |
| `Nyanform.ClientFamiliar` | Name-based `auto` profile selection. |
| `Nyanform.Session.Thread` | One logical MCP session and one upstream connection. |
| `Nyanform.Session.Manager` | HTTP session lifecycle and limits. |
| `Nyanform.Transport.UpstreamShrine` | Upstream stdio port or HTTP client. |
| `Nyanform.Transport.DownstreamStdio` | Client-facing line-delimited stdio loop. |
| `Nyanform.Transport.DownstreamHttp` / `HttpPlug` | Client-facing Streamable HTTP server and routes. |
| `Nyanform.Diagnostic.Omen` / `Codes` | Runtime diagnostic value and code catalog. |
| `Nyanform.CLI` | `serve`, `inspect`, `matrix`, `snapshot`, `check`, and `doctor`. |
