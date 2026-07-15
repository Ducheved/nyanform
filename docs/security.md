# Security model

Nyanform sits between an MCP client and an MCP server. Client frames, upstream
responses, tool schemas, tool arguments, and tool results must all be treated
as untrusted. The operator is assumed to control the host and the local
configuration file.

The repository does not currently publish a verified private vulnerability
intake channel. Follow [../SECURITY.md](../SECURITY.md) before sharing sensitive
details, and do not put exploit material or secrets in a public issue.

## Active resource boundaries

Defaults are seeded in `mix.exs` and read by the active paths shown below.

| Setting | Default | Current behavior |
|---|---:|---|
| `max_message_size` | 1 MiB | `Protocol.Message.parse/2` rejects oversized serialized JSON-RPC messages. Downstream stdio, downstream HTTP parsing, upstream stdio parsing, and parsed upstream HTTP/SSE events pass this value through. |
| `max_schema_depth` | 64 | `Schema.Parser.parse/4` returns `schema_depth_exceeded` once recursive descent exceeds the limit. |
| `max_reference_depth` | 32 | `Schema.Pipeline` stops following local definition references during recursive-reference marking and marks the reference recursive. This is a traversal bound, not a schema rejection rule. |
| `max_tool_count` | 1024 | Live `Session.Thread` catalogs and the full-catalog `inspect`, `matrix`, `snapshot`, and `check` fetch stop with a controlled error above the limit. |
| `max_concurrent_compilation` | 8 | The `matrix` command uses it as `Task.Supervisor.async_stream/4` concurrency. |
| `max_http_body_size` | 4 MiB | Downstream HTTP checks content length and calls `Plug.Conn.read_body/2` with this limit. |
| `request_timeout_ms` | 30 seconds | Upstream calls use the configured `GenServer.call/3` timeout; Req also receives it as `receive_timeout`. Tests override the application default with a shorter value. |

`max_diagnostic_count` is present in `Nyanform.Limits`, but no diagnostic
accumulator currently consumes it. It is a configuration placeholder, not an
enforced security boundary.
`Nyanform.Limits.from_config/1` also exists, but callers that use
`Limits.default/0` do not automatically receive arbitrary values passed to
that helper.

### JSON decoding and HTTP buffering

For line-oriented stdio, Nyanform checks byte size before `Jason.decode/1`.
Downstream HTTP also bounds body reading before parsing. Upstream HTTP responses
are fetched by Req and then passed to the bounded message/SSE parser; the
current code does not impose a separate pre-buffer response-body limit in Req.
Operators should therefore treat an untrusted upstream HTTP endpoint as capable
of consuming memory before Nyanform rejects an oversized parsed message.

### Schema and reference traversal

The parser increments a depth counter on recursive schema descent and fails
when the configured schema depth is exceeded. During pipeline compilation,
local references are followed with a `seen` map and a reference-depth counter.
A repeated or over-depth local reference is marked `recursive: true` rather
than expanded indefinitely. `Schema.Reference.detect_cycles/2` is also
available as a utility, but the pipeline's protection comes from its own
bounded `mark_recursive` traversal.

`Reference.normalize_definition_refs/1` and `dangling_local_refs/1` also use
`max_schema_depth` while traversing modeled and unmodeled raw schema trees.
They stop descending at the boundary; dangling targets below that boundary are
left unclassified rather than reported from an unbounded scan.

### Request cleanup

Pending upstream requests are tracked by JSON-RPC ID. Caller timeout paths
cancel their pending entry, and upstream close/exit paths reply to all waiting
callers before the transport process stops. The timeout limits waiting time;
it is not authentication, rate limiting, or a total CPU/memory budget.

## Child process execution and environment

Upstream stdio servers are opened with Erlang `Port.open/2` and
`:spawn_executable`. Commands and arguments are passed directly as an
executable plus an argument list; Nyanform does not construct a shell command.
`System.find_executable/1` is used when possible, and the literal command is
passed to the port when lookup fails.

The child environment is rebuilt rather than inherited wholesale:

- Existing parent variables are cleared for the child.
- A minimal set of system variables needed to locate and launch programs is
  restored.
- Names listed in `envAllowlist` are inherited.
- Explicit upstream `env` entries are applied last and therefore win on key
  collisions.

The configuration loader validates that upstream environment keys and values
are strings. Invalid environment configuration errors use a redacted marker
instead of returning the supplied map or value. This does not sanitize the
configuration file itself or values later placed in a schema, description, or
report.

## Redaction boundaries

`Nyanform.RewriteTalisman.redact_secrets/2` recursively replaces values when a
map key contains one of the configured secret substrings. Matching is
case-insensitive and key-based. The helper does not identify secrets stored
under innocuous keys and is not automatically applied to every serializer or
reporter.

Current Nyanform code does not intentionally log tool-call argument maps or
upstream environment values. That is narrower than a guarantee that every
artifact is secret-free:

- `snapshot` preserves raw `serverInfo`, capabilities, tool descriptions,
  input schemas, and output schemas, in addition to schema digests and kinds.
- Schemas may contain credentials in descriptions, defaults, examples,
  annotations, enum/const values, or vendor extensions.
- Inspection reports contain schema-derived diagnostics and selected server
  metadata. Matrix reports contain schema-derived per-profile results without
  server metadata.
- The redaction helper only protects data paths that explicitly call it.

Review generated snapshots and reports before committing or uploading them.
Do not use a snapshot as a secret store, and do not assume it is safe merely
because it contains no tool-call arguments.

## Downstream HTTP exposure

The downstream HTTP server binds to `127.0.0.1` by default. Changing `host` or
using `--host` can expose it to other interfaces. Nyanform does not provide TLS,
client authentication, or authorization; use an appropriately configured
reverse proxy when those controls are required.

Requests without an `Origin` header are accepted for non-browser MCP clients.
When an allowlist is configured, an Origin must match it exactly. With no
allowlist, Origin-bearing requests are accepted only when both the bind address
and parsed Origin are loopback. This Origin check is a browser-facing boundary,
not an authentication mechanism.

## Stdio protocol purity

In stdio serve mode, stdout is the downstream JSON-RPC transport. Nyanform
writes its own status and error output to stderr and writes downstream protocol
messages to stdout. Adding arbitrary stdout output to this path can corrupt the
stream and is a security and reliability regression.

An upstream program that writes banners or logs to its own stdout still sends
those bytes into Nyanform's upstream parser. Such output can cause parse errors;
the purity statement covers Nyanform's downstream stdout, not arbitrary
behavior by an upstream process.

## Controls Nyanform does not provide

- Client or upstream authentication and authorization.
- TLS termination.
- General request-rate limiting.
- A currently enforced maximum diagnostic count.
- Automatic secret scanning or universal redaction of snapshots and reports.
- A verified private vulnerability mailbox or response/remediation SLA.
