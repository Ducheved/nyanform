# Nyanform

Make one MCP server work everywhere.

Nyanform is a local-first MCP compatibility proxy and schema compiler. It sits between an MCP client and an MCP server, compiles upstream tool schemas into a canonical representation, and produces a compatible schema dialect for the connected client.

## Quick start

```sh
mix nyanform inspect --stdio-command node --stdio-arg server.js
```

## Compatibility report

```
Profile        Policy  Tools  Accepted  Worst     Omens  Duration
-------------------------------------------------------------------
canonical      strict  10     yes       exact     1      43.2ms
claude         strict  10     no        rejected  1      43.1ms
gemini         strict  10     no        rejected  4      43.1ms
openai_strict  strict  10     no        rejected  5      43.1ms
passthrough    strict  10     yes       exact     1      43.2ms
vscode         strict  10     no        rejected  1      43.0ms
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

### Claude Code (stdio to stdio)

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

### Cursor / OpenAI strict (stdio to stdio)

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

- **Schema compiler** — parses JSON Schema into a canonical `Scroll` struct, resolves references, detects cycles, and computes deterministic digests.
- **Compatibility profiles** — declarative data describing what each MCP client accepts. A shared projector compiles canonical schemas into client-specific dialects, emitting structured omens for every transformation.
- **Proxy lifecycle** — OTP-supervised session processes that intercept `tools/list` and `tools/call`, project schemas, repair arguments, and transparently pass through all other JSON-RPC messages.
- **Transports** — stdio and Streamable HTTP for both downstream (client-facing) and upstream (server-facing) connections.
- **CLI** — `serve`, `inspect`, `matrix`, `snapshot`, `check`, and `doctor` commands.

See [docs/architecture.md](docs/architecture.md) for details.

## Commands

| Command | Description |
|---------|-------------|
| `nyanform serve` | Run as a proxy between a client and an upstream MCP server |
| `nyanform inspect` | Connect to a server, validate schemas, print a report |
| `nyanform matrix` | Compile a server against every compatibility profile |
| `nyanform snapshot` | Save a deterministic canonical snapshot |
| `nyanform check` | Compare a live server with a stored snapshot |
| `nyanform doctor` | Check configuration and environment |

## License

MIT. See [LICENSE](LICENSE).
