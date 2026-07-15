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

Choose a profile from the schema contract you need, not from a client brand
alone. An explicit `--profile` makes the projection reproducible. Vendor-named
profiles are Nyanform compatibility presets; they are not proof that every
version, model provider, or adapter used by that client accepts the projected
schema.

| Profile | Choose it when | Current behavior |
|---------|----------------|------------------|
| `canonical` | You want Nyanform's normalized schema dialect, or no client-specific contract is known. | Parses and re-emits the modeled subset, preserves boolean schemas, and emits a rejected diagnostic for unmodeled keywords such as `prefixItems`. This is the default, but it is not raw pass-through or a proof of MCP conformance. |
| `passthrough` | You need the upstream schema value unchanged. | Returns the retained raw schema and preserves undeclared required names, while still reporting dangling local JSON Pointer targets found within the bounded traversal. |
| `openai_strict` | The downstream contract explicitly requires OpenAI strict function schemas. | Enforces the documented strict object shape described below. This is not a Cursor, Continue, or Codex profile. |
| `gemini` | You are testing Nyanform's hypothesis informed by the Gemini CLI MCP sanitizer. | Applies the repository preset; the CLI still performs its own documented sanitization after discovery. |
| `claude` | You intentionally want to test Nyanform's Claude-oriented preset. | Supports the rules encoded in the repository, but is not an official or exhaustive Claude Code specification. |
| `vscode` | You intentionally want to test Nyanform's VS Code-oriented preset. | A repository compatibility preset, not an official Microsoft schema contract. |

Projection policy is independent of profile selection:

| Policy | Acceptance rule |
|--------|-----------------|
| `strict` | Rejects a tool when projection produces a `lossy` or `rejected` omen. This is the default. |
| `compatible` | Accepts exact, normalized, and lossy projections, but still rejects `rejected` omens. |
| `permissive` | Accepts ordinary rejected profile omens, but dangling local references and required-name loss in a profile rewrite remain unaccepted. The live catalog can still publish structurally publishable rejected schemas; malformed tool envelopes stay hidden and downstream support is not guaranteed. |

### Auto-detection (`--profile auto`)

`Nyanform.ClientFamiliar.detect/1` inspects the `clientInfo.name` field using a
case-insensitive substring match. These are the complete mappings currently in
the code:

| Pattern in client name | Selected profile |
|------------------------|------------------|
| `claude` | `claude` |
| `cline` | `claude` |
| `openai` | `openai_strict` |
| `gemini` | `gemini` |
| `vscode` / `vs code` | `vscode` |
| (anything else) | `canonical` (with `confidence: :unknown`) |

There are no dedicated `cursor`, `continue`, or `codex` mappings. Those names
fall back to `canonical` unless the actual advertised name also contains one of
the patterns in the table. `confidence: :known` means that a name pattern
matched; it is not an integration certification.

Auto-detection happens at `initialize` time inside the session thread, so the
profile is locked in before the first `tools/list` is projected. An explicitly
selected profile bypasses this detection.

---

## Claude Code (stdio to stdio)

Add Nyanform to your `mcpServers` configuration, pointing at the upstream
server you want to wrap. This example explicitly opts into Nyanform's `claude`
preset; it does not assert that the preset is a complete Claude Code contract:

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

To use the name-based heuristic instead of a fixed profile, set
`--profile auto`. A `clientInfo.name` containing `claude` selects `claude`:

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

Cursor has no dedicated profile or auto-detection rule in Nyanform. Choose the
profile explicitly from the schema behavior you have verified for the actual
Cursor model/provider path. This configuration starts with normalized
`canonical` output:

```json
{
  "mcpServers": {
    "nyanform": {
      "command": "nyanform",
      "args": [
        "serve",
        "--stdio-command", "node",
        "--stdio-arg", "server.js",
        "--profile", "canonical"
      ]
    }
  }
}
```

Use `passthrough` instead if Cursor must receive the original schema unchanged.
Select `openai_strict` only when you have established that the concrete
downstream path requires OpenAI strict function schemas. The same evidence
boundary applies to Continue and Codex; Nyanform does not assign any of these
client names to `openai_strict` automatically. See Cursor's
[MCP configuration documentation](https://docs.cursor.com/context/model-context-protocol)
for the client-side configuration surface.

---

## OpenAI strict function tools

The `openai_strict` profile models the documented subset for
[OpenAI strict function calling](https://developers.openai.com/api/docs/guides/function-calling)
and [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs).
It is a schema target, not a general profile for applications that happen to
offer an OpenAI model.

The current projector applies these rules:

- the root must be an object; a root `anyOf` is rejected;
- every property of every object is added to `required`; an originally optional
  property gains `null`, and a synthetic `null` is removed before the upstream
  call;
- every object is closed with `additionalProperties: false`; changing an open
  source object is lossy, so `strict` rejects it and `compatible` permits it;
- nested `anyOf`, nullable type unions, local `$defs`, and local `$ref` are
  supported;
- `const` is rewritten to an equivalent single-value `enum`; unsupported
  keywords such as `minLength` and `maxLength` are omitted with a lossy omen;
- `allOf` is unsupported: `strict` rejects the tool, while looser policies may
  merge compatible object branches and report the transformation;
- object nesting is limited to ten levels.

Inspect the actual upstream server before configuring a downstream integration:

```sh
nyanform inspect \
  --stdio-command node \
  --stdio-arg server.js \
  --profile openai_strict \
  --policy strict
```

---

## Gemini CLI (stdio to stdio)

Gemini CLI documents its own MCP discovery sanitizer. It removes `$schema`,
removes `additionalProperties`, removes `default` from `anyOf` branches, and
sanitizes or truncates tool names before exposing fully qualified names. See
the official [Gemini CLI MCP server documentation](https://geminicli.com/docs/tools/mcp-server/).

Nyanform's `gemini` hypothesis treats `additionalProperties: false` as acceptable
input and preserves it in Nyanform's projected schema. Gemini CLI then removes
that keyword during its own discovery step. This is intentional: the profile
approximates whether the input can cross the CLI boundary; it is not a byte-for-byte copy
of the CLI's post-sanitization schema. The Gemini API's structured-output
schema also documents `additionalProperties` as a boolean or schema; that is a
separate API surface from the CLI sanitizer. See the
[Gemini structured output reference](https://ai.google.dev/gemini-api/docs/structured-output).

Within the current Nyanform preset, `const` becomes an equivalent single-value
`enum`, tuple arrays are unsupported, and enum values must be homogeneous. Use
`compatible` when you intentionally allow reported lossy rewrites while still
rejecting unsupported projections:

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

Run an explicit inspection first to see which tools Nyanform will accept or
reject before wiring up the client:

```sh
nyanform inspect \
  --stdio-command node \
  --stdio-arg server.js \
  --profile gemini \
  --policy compatible
```

---

## VS Code (stdio to HTTP)

VS Code's MCP integration can talk to either stdio or HTTP servers. To
expose Nyanform over HTTP (useful when multiple VS Code windows or other
tools want to share one proxy), this example explicitly opts into Nyanform's
`vscode` preset. The preset is not an official Microsoft schema specification.

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
configuration. A valid headerless `initialize` creates a server-generated
`mcp-session-id`; later requests must return that ID. An unknown incoming ID
is rejected rather than adopted.

---

## stdio to HTTP (Nyanform wraps a remote server)

If your MCP server already runs as an HTTP service, point Nyanform at it
with `--http-endpoint` instead of `--stdio-command`:

```sh
nyanform serve \
  --http-endpoint https://internal.example.com/mcp \
  --profile canonical
```

Nyanform creates the upstream HTTP session with its own initialize request,
answers each downstream initialize locally, projects tool schemas for the
configured profile, and exposes the result over its own stdio (default) or
HTTP downstream.

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
message/body size limits, environment variables, allowed HTTP origins, and
tool include/exclude lists in one place.

---

## Verifying your setup

Before pointing a real client at Nyanform, run `inspect` and `matrix` to
confirm the projection works as expected:

```sh
nyanform inspect --stdio-command node --stdio-arg server.js --profile canonical
nyanform matrix   --stdio-command node --stdio-arg server.js --format sarif -o matrix.sarif
nyanform doctor
```

- `inspect` shows per-tool diagnostics for one profile.
- `matrix` compiles the server against all six profiles and reports which
  accept or reject each tool.
- `doctor` reports the current Elixir version and checks configuration, the
  profile catalog, and protocol support. It does not enforce an Elixir version
  range.

If `inspect` reports rejections under your chosen profile, either adjust the
upstream schema or choose a different profile based on the real downstream
contract. A looser policy changes Nyanform's acceptance decision; it does not
make an unsupported downstream schema compatible.
