# Client setup

This guide shows how to point common MCP clients at Nyanform. Nyanform
supports two downstream transports:

- **stdio** — Nyanform reads JSON-RPC from stdin and writes to stdout. This
  is what most MCP clients expect from a locally-spawned server.
- **Streamable HTTP** — Nyanform exposes an HTTP endpoint that clients
  POST JSON-RPC requests to.

And two upstream transports:

- **stdio** — Nyanform spawns the upstream MCP server as a child process.
- **HTTP** — Nyanform connects to an upstream MCP server over HTTP.

The common combinations are **stdio to stdio** (Nyanform spawned by the
client, Nyanform spawns the server) and **stdio to HTTP** (Nyanform
spawned by the client, Nyanform proxies to a remote HTTP server).

---

## Profile selection guide

Pick the profile that matches your client. If you are unsure, use
`--profile auto` and Nyanform will detect the client from the
`clientInfo` field of the `initialize` request.

| Client | Recommended profile | Notes |
|--------|---------------------|-------|
| Claude Code, Cline | `claude` | Supports oneOf/anyOf/allOf, local refs, const. |
| Cursor, Continue, OpenAI | `openai_strict` | Strict function-calling: all properties required, no combinators, no refs. |
| Gemini CLI | `gemini` | No const, no tuple arrays, no mixed enums. |
| VS Code (MCP UI) | `vscode` | Most permissive of the vendor profiles. |
| Any client, no rewriting | `passthrough` | Forwards schemas unchanged; useful for debugging. |
| Canonical Nyanform output | `canonical` | The reference dialect; no projection. |

### Auto-detection (`--profile auto`)

`Nyanform.ClientFamiliar.detect/1` inspects the `clientInfo.name` field
(case-insensitive substring match) and selects a profile:

| Pattern in client name | Selected profile |
|------------------------|------------------|
| `claude` | `claude` |
| `cline` | `claude` |
| `cursor` | `openai_strict` |
| `continue` | `openai_strict` |
| `openai` | `openai_strict` |
| `gemini` | `gemini` |
| `vscode` / `vs code` | `vscode` |
| (anything else) | `canonical` (with `confidence: :unknown`) |

Auto-detection happens at `initialize` time inside the session thread, so
the profile is locked in before the first `tools/list` is projected.

---

## Claude Code (stdio to stdio)

Add Nyanform to your `mcpServers` configuration, pointing at the upstream
server you want to wrap:

```json
{
  "mcpServers": {
    "nyanform": {
      "command": "/absolute/path/to/nyanform",
      "args": [
        "serve",
        "--stdio-command", "node",
        "--stdio-arg", "server.js",
        "--profile", "claude"
      ]
    }
  }
}
```

If `nyanform` is installed on `PATH`, replace the absolute `command` path
with `nyanform`.

To use auto-detection instead of a fixed profile, set `--profile auto`:

```json
{
  "mcpServers": {
    "nyanform": {
      "command": "nyanform",
      "args": [
        "serve",
        "--stdio-command", "node",
        "--stdio-arg", "server.js",
        "--profile", "auto"
      ]
    }
  }
}
```

---

## Cursor (stdio to stdio)

Cursor's MCP configuration lives in its settings. Use the `openai_strict`
profile, since Cursor's tool-call schema follows OpenAI's strict
function-calling shape:

```json
{
  "mcpServers": {
    "nyanform": {
      "command": "nyanform",
      "args": [
        "serve",
        "--stdio-command", "node",
        "--stdio-arg", "server.js",
        "--profile", "openai_strict",
        "--policy", "compatible"
      ]
    }
  }
}
```

The `compatible` policy is recommended for Cursor: it allows lossy
rewrites (e.g. dropping `additionalProperties: false`) while still
rejecting genuinely unsupported constructs. Use `strict` if you want hard
failures on any information loss.

---

## Gemini CLI (stdio to stdio)

Gemini is the most restrictive of the built-in profiles (no const, no
tuple arrays, no mixed enums, no `additionalProperties: false`). Use
`compatible` or `permissive` policy if your server uses constructs Gemini
cannot represent:

```json
{
  "mcpServers": {
    "nyanform": {
      "command": "nyanform",
      "args": [
        "serve",
        "--stdio-command", "node",
        "--stdio-arg", "server.js",
        "--profile", "gemini",
        "--policy", "compatible"
      ]
    }
  }
}
```

Run `nyanform inspect --profile gemini` first to see which tools will be
rejected before wiring up the client.

---

## VS Code (stdio to HTTP)

VS Code's MCP integration can talk to either stdio or HTTP servers. To
expose Nyanform over HTTP (useful when multiple VS Code windows or other
tools want to share one proxy):

Start Nyanform as a long-running HTTP server:

```sh
nyanform serve \
  --downstream-transport http \
  --port 8080 \
  --host 127.0.0.1 \
  --allowed-origin https://vscode.dev \
  --stdio-command node \
  --stdio-arg server.js \
  --profile vscode
```

Then point VS Code at `http://127.0.0.1:8080/` in its MCP server
configuration. The `mcp-session-id` header is honored: VS Code can send a
stable session ID and Nyanform will reuse the same session thread across
requests.

---

## stdio to HTTP (Nyanform wraps a remote server)

If your MCP server already runs as an HTTP service, point Nyanform at it
with `--http-endpoint` instead of `--stdio-command`:

```sh
nyanform serve \
  --http-endpoint https://internal.example.com/mcp \
  --profile claude
```

Nyanform will forward the MCP initialize handshake to the upstream over
HTTP, project tool schemas for the configured profile, and expose the
result over its own stdio (default) or HTTP downstream.

---

## Using a config file

For non-trivial deployments, prefer a `nyanform.json` config file over
long command lines. See [../examples/nyanform.json](../examples/nyanform.json)
for a fully documented sample, and [../priv/nyanform.schema.json](../priv/nyanform.schema.json)
for the JSON Schema that validates it.

```sh
nyanform serve --config nyanform.json
```

The config file lets you set both transports, the profile, the policy,
resource limits, environment variables, allowed HTTP origins, and tool
include/exclude lists in one place.

---

## Verifying your setup

Before pointing a real client at Nyanform, run `inspect` and `matrix` to
confirm the projection works as expected:

```sh
nyanform inspect --stdio-command node --stdio-arg server.js --profile claude
nyanform matrix   --stdio-command node --stdio-arg server.js --format sarif -o matrix.sarif
nyanform doctor
```

- `inspect` shows per-tool diagnostics for one profile.
- `matrix` compiles the server against all six profiles and reports which
  accept or reject each tool.
- `doctor` checks the Elixir version, configuration, profile catalog, and
  protocol support.

If `inspect` reports rejections under your chosen profile, either adjust
the upstream schema, switch to a more permissive policy, or pick a
different profile.
