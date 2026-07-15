# Nyanform

Inspect and adapt MCP tool schemas across client boundaries.

Nyanform is a local-first MCP compatibility proxy and schema compiler. It sits between an MCP client and an MCP server, compiles upstream tool schemas into a canonical representation, and projects them into an explicitly selected schema profile.

## Quick start

```sh
mix nyanform inspect --stdio-command node --stdio-arg server.js
```

## Installation

### From source

```sh
git clone https://github.com/Ducheved/nyanform.git
cd nyanform
mix setup
```

### Standalone executable (escript)

```sh
mix escript.build
./nyanform --help
./nyanform inspect --stdio-command node --stdio-arg server.js
```

### Docker

```sh
docker build -t nyanform .
docker run --rm -i \
  -v "$PWD/server.js:/work/server.js:ro" \
  nyanform inspect --stdio-command node --stdio-arg /work/server.js
```

## Client configuration examples

Profiles are transformation targets, not certifications for an entire client.
Prefer an explicit `--profile` when the downstream schema contract is known.
`--profile auto` is only a `clientInfo.name` heuristic; unknown names use
`canonical`.

### Claude Code with an explicit preset (stdio to stdio)

This opts into Nyanform's `claude` compatibility preset. The preset is not an
official or exhaustive Claude Code schema specification, so verify the actual
server and client combination before relying on it.

```json
{
  "mcpServers": {
    "nyanform": {
      "command": "/absolute/path/to/nyanform",
      "args": ["serve", "--stdio-command", "node", "--stdio-arg", "server.js", "--profile", "claude"]
    }
  }
}
```

### OpenAI strict projection (stdio to stdio)

Select `openai_strict` only when the downstream tool contract requires
[OpenAI strict function schemas](https://developers.openai.com/api/docs/guides/function-calling).
Nyanform does not infer this profile merely because the client is Cursor,
Continue, or Codex.

```json
{
  "mcpServers": {
    "nyanform": {
      "command": "nyanform",
      "args": ["serve", "--stdio-command", "node", "--stdio-arg", "server.js", "--profile", "openai_strict"]
    }
  }
}
```

The profile requires an object root, represents optional properties as required
nullable fields, closes every object with `additionalProperties: false`,
accepts nested `anyOf` and local `$defs`/`$ref`, and treats `allOf` as
unsupported. Closing an open source object is lossy, so use `compatible` to
permit that adaptation; `strict` accepts only already-closed source objects.

### Canonical and passthrough

- `canonical` parses and usually re-emits schemas in Nyanform's normalized
  dialect. An untyped or otherwise unknown `Scroll` uses its retained raw
  schema as a fallback, and JSON Schema boolean values remain `true` or
  `false`. Keywords outside Nyanform's modeled subset, including
  `prefixItems`, emit a rejected diagnostic instead of disappearing silently.
  The profile is the default for unknown clients.
- `passthrough` bypasses schema projection and forwards each original schema
  value unchanged after structural compilation succeeds. Use it when preserving
  the upstream schema is more important than normalization or projection
  diagnostics, including when a tool depends on `prefixItems`.
- `gemini` is a compatibility hypothesis informed by the documented Gemini CLI MCP sanitizer. Nyanform accepts and
  preserves `additionalProperties: false`; the
  [Gemini CLI sanitizer](https://geminicli.com/docs/tools/mcp-server/) removes
  `additionalProperties` later during tool discovery.

### Streamable HTTP downstream

```sh
nyanform serve \
  --downstream-transport http \
  --port 8080 \
  --stdio-command node \
  --stdio-arg server.js \
  --profile auto
```

### Using a config file

```sh
nyanform serve --config nyanform.json
```

## Architecture summary

Nyanform is an Elixir/OTP application with these core layers:

- **Schema compiler** — parses and canonicalizes JSON Schema into a `Scroll` struct, marks bounded recursive references, and computes deterministic digests.
- **Compatibility profiles** — declarative projection targets. A shared projector emits structured omens for selected rewrites and incompatibilities; vendor-named presets are not integration guarantees.
- **Proxy lifecycle** — OTP-supervised session processes intercept `tools/list` and `tools/call`, project schemas, repair arguments, and semantically relay the supported JSON-RPC shape for other messages.
- **Transports** — stdio and Streamable HTTP for both downstream (client-facing) and upstream (server-facing) connections.
- **CLI** — `serve`, `inspect`, `matrix`, `snapshot`, `check`, and `doctor` commands.

See [docs/architecture.md](docs/architecture.md) for details.

## Commands

| Command | Description |
|---------|-------------|
| `nyanform serve` | Run as a proxy between a client and an upstream MCP server |
| `nyanform inspect` | Connect to a server, validate schemas, print a report |
| `nyanform matrix` | Compile a server against every compatibility profile |
| `nyanform snapshot` | Save selected catalog fields in name order with canonical input digests |
| `nyanform check` | Compare a live server with a stored snapshot |
| `nyanform doctor` | Check configuration and environment |

## License

MIT. See [LICENSE](LICENSE).
