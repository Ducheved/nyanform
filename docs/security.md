# Security

Nyanform sits between an MCP client and one or more MCP servers. Both sides
are **untrusted**: the client may send malformed JSON-RPC, the server may
return adversarial schemas, and tool arguments and results may contain
attacker-controlled data. This document describes the defenses Nyanform
applies and the threat model it assumes.

If you believe you have found a security vulnerability, please follow the
private disclosure process in [../SECURITY.md](../SECURITY.md) rather than
opening a public issue.

---

## Threat model

Nyanform treats all of the following as untrusted input:

- **MCP servers** (upstream). A server may be compromised or malicious.
  Its `tools/list` response, `initialize` result, and `tools/call` results
  are all attacker-controlled.
- **MCP clients** (downstream). A client may send malformed frames,
  oversized messages, or arguments designed to exploit a server.
- **Tool schemas.** Schemas returned by `tools/list` are parsed,
  canonicalized, and projected. A malicious schema may be deeply nested,
  cyclic, or constructed to exhaust memory.
- **Tool arguments.** Arguments in `tools/call` are forwarded to the
  upstream. They may be oversized, malformed, or contain secrets.
- **Tool results.** Results from the upstream are forwarded to the client
  unchanged in the current implementation, but the secret-redaction
  helpers exist for use in diagnostics and reports.

Nyanform assumes the operator controls the host on which it runs and the
`nyanform.json` configuration file. It does not assume the operator
controls the upstream server or the downstream client.

---

## Resource limits

All limits are centralized in `Nyanform.Limits` and seeded from
application environment (`mix.exs` `env/0`):

| Limit | Default | Enforced by |
|-------|---------|-------------|
| `max_message_size` | 1,048,576 bytes (1 MiB) | `Protocol.Message.parse/2` rejects frames exceeding this with `message_too_large`. |
| `max_schema_depth` | 64 | `Schema.Parser.parse/4` returns `schema_depth_exceeded`. |
| `max_reference_depth` | 32 | `Schema.Reference.resolve/5` and `Pipeline.mark_recursive/5` bound ref traversal. |
| `max_tool_count` | 1024 | Catalog builder upper bound. |
| `max_concurrent_compilation` | 8 | `Task.Supervisor.async_stream` concurrency in the matrix command. |
| `max_http_body_size` | 4,194,304 bytes (4 MiB) | `Plug.Conn.read_body/2` `length` option in `HttpPlug`. |
| `max_diagnostic_count` | 4096 | Diagnostic accumulator upper bound. |
| `request_timeout_ms` | 30,000 ms (5,000 ms in test) | `UpstreamShrine.request/2` GenServer call timeout; also `Req` `receive_timeout`. |

### Bounded JSON decoding

`Message.parse/2` checks the byte size of the incoming line **before**
calling `Jason.decode/1`. A frame larger than `max_message_size` is
rejected with `{:error, {:message_too_large, size}}` and never reaches the
JSON decoder. This prevents a single oversized frame from exhausting the
beam's binary heap.

`HttpPlug` reads the request body with `Plug.Conn.read_body/2` and a
`length` option, so Bandit will not buffer an unbounded request body into
memory.

### Schema depth limits

The parser carries a `depth` counter incremented on each recursive descent.
When `depth > max_schema_depth`, parsing fails fast with
`schema_depth_exceeded`. This defeats schemas constructed as a single
deeply-nested object whose only purpose is to consume stack.

### Reference cycle detection

`Reference.detect_cycles/2` walks the `$ref` graph with a `seen` MapSet.
If a target is revisited on the current path, the cycle is detected and
the ref is marked `recursive: true` rather than being inlined. Even if a
cycle slips past detection, `resolve/5` and `mark_recursive/5` bound
traversal at `max_reference_depth`, so a malicious cyclic schema cannot
cause infinite recursion.

---

## Request timeout handling

Every upstream request goes through `UpstreamShrine.request/2`, which is a
`GenServer.call/3` with a timeout read from `application_env(:request_timeout_ms)`.
The HTTP transport additionally passes `receive_timeout` to `Req.post/2`.
If the upstream does not respond within the timeout, the call returns
`{:error, :timeout}` and the proxy replies to the client with a
JSON-RPC `-32603` internal error.

Pending requests are tracked in a `requests` map keyed by message ID. If
the upstream port exits (`{:exit_status, status}`) or the HTTP socket
closes (`:tcp_closed` / `:ssl_closed`), `fail_all_requests/2` replies to
every waiting caller with `{:error, reason}` and the GenServer stops
normally, so the dynamic supervisor can clean up the session.

---

## Secret redaction

`Nyanform.RewriteTalisman.redact_secrets/2` recursively replaces values
whose key matches a secret pattern with the literal string `"[REDACTED]"`.
The default secret-key substrings are:

```
password secret token api_key apikey access_key private_key credential auth cookie session
```

Matching is case-insensitive substring: any key containing one of these
substrings (e.g. `user_password`, `x_api_key`, `sessionToken`) is
redacted. The function recurses into nested maps and lists.

This helper is intended for use when emitting diagnostics or reports that
might otherwise leak argument contents. Nyanform does not log raw tool
arguments or raw environment values; when an argument must appear in a
report, it should be passed through `redact_secrets/2` first.

---

## Safe child process spawning

Upstream stdio servers are spawned via Erlang ports with
`:spawn_executable`:

```elixir
Port.open({:spawn_executable, to_charlist(find_executable(cmd))}, port_args)
```

This invokes the executable **directly**, never through a shell. There is
no `sh -c`, so shell metacharacters in the command or arguments cannot
cause command injection. The executable path is resolved through
`System.find_executable/1`; if not found, the literal command string is
used (and the port will fail to start, which the session thread surfaces
as `upstream_start_failed`).

Arguments are passed as a list (`args: args`), not a single string, so
each argument is delivered to the child process verbatim without shell
splitting.

---

## Environment variable allowlisting

When spawning an upstream stdio process, Nyanform does **not** inherit the
parent environment wholesale. It preserves a minimal set of system
variables needed to locate and launch child processes, then inherits only
the additional names listed in `envAllowlist`.

Values supplied explicitly through `--env KEY=VALUE` or the upstream
`env` map in `nyanform.json` are applied last and override inherited values
with the same name. All other parent environment variables are cleared for
the child process.

---

## Local-only HTTP binding by default

`DownstreamHttp.run/4` defaults `host` to `"127.0.0.1"`. The HTTP server
listens only on the loopback interface unless the operator explicitly
configures a different `host` (via `--host` on the CLI or the `host` field
in `nyanform.json`). This means a default deployment is not reachable from
other machines on the network.

Operators who need to expose Nyanform to other hosts (e.g. behind a
reverse proxy) must opt in explicitly. Nyanform does not provide TLS
termination itself; put it behind a TLS-terminating reverse proxy if you
need encrypted transport.

For browser-facing HTTP deployments, repeat `--allowed-origin` for each
accepted Origin or set `downstream.allowedOrigins` in `nyanform.json`.
With the empty default, requests without an Origin header are accepted
for non-browser MCP clients. Origin-bearing requests are accepted by
default only for loopback Origins when Nyanform is bound to loopback.
Non-loopback binds require an explicit list; configured Origins require
an exact match.

---

## No raw arguments or env values in logs and reports

- Tool arguments are never written to logs at any level. The logger
  configuration in `config/config.exs` carries `:session_id`, `:profile`,
  and `:tool` metadata, but not argument payloads.
- Environment variable values configured for the upstream are passed to
  the port and not echoed back in diagnostics or reports. Only the keys
  appear in error messages if a spawn fails.
- Snapshot files written by `nyanform snapshot` contain the schema and a
  digest, not the arguments of any call.
- Reports produced by `nyanform inspect` and `nyanform matrix` contain
  schema paths and explanations, never argument values.

If you need to capture arguments for debugging, route them through
`RewriteTalisman.redact_secrets/2` first and write them to a location you
control.

---

## stdout protocol purity in stdio mode

In stdio mode, Nyanform's stdout is the JSON-RPC transport. Anything
written to stdout that is not a valid JSON-RPC frame corrupts the protocol
and can hang or crash the client. Nyanform enforces stdout purity:

- All diagnostics, status messages, and error reports are written to
  **stderr** (`IO.write(:stderr, ...)`), never stdout.
- The downstream stdio loop (`DownstreamStdio`) only writes encoded
  `Message` structs to stdout, each followed by a single newline.
- The `NYA-TRANSPORT-005` diagnostic ("stdout protocol purity enforced")
  documents this invariant.

This matters because some MCP servers print banner text or progress logs
to stdout. When Nyanform is the upstream (i.e. when chaining proxies), it
guarantees its own stdout is pure JSON-RPC.
