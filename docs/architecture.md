# Architecture

Nyanform is a local-first MCP compatibility proxy and schema compiler written
in Elixir/OTP. It sits between an MCP client and an MCP server, compiles the
upstream server's tool schemas into a canonical representation, and projects a
client-specific dialect that the connected client can actually consume. Every
transformation is recorded as a structured diagnostic ("omen") so that
information loss is observable and auditable.

This document describes the supervision tree, dependency choices, schema
pipeline, session lifecycle, and the module map.

---

## OTP supervision tree

`Nyanform.Application` implements `Application.start/2` and starts a single
top-level supervisor (`Nyanform.Supervisor`) with strategy `:one_for_one`.
The supervisor owns three children:

| Child | Type | Role |
|-------|------|------|
| `Nyanform.Session.Registry` | `Registry` (`keys: :unique`) | Maps session IDs to `Session.Thread` PIDs. |
| `Nyanform.Session.Supervisor` | `DynamicSupervisor` (`:one_for_one`) | Starts and supervises one `Session.Thread` per active session. |
| `Nyanform.Compile.TaskSupervisor` | `Task.Supervisor` (`max_children: 32`) | Runs matrix compilation across profiles concurrently. |

A session is created lazily:

- In **stdio downstream** mode, `DownstreamStdio.run/3` generates a fresh
  session ID and calls `Session.Thread.initialize/4`, which starts a
  `Session.Thread` under the dynamic supervisor and registers it in the
  registry.
- In **HTTP downstream** mode, `HttpPlug` reuses an incoming
  `mcp-session-id` header if present, otherwise generates one and starts a
  session via `ensure_session/4`.

If a `Session.Thread` crashes, the dynamic supervisor restarts only that
session; other sessions and the compile task supervisor are unaffected. The
top-level strategy is `:one_for_one`, so a child crash never cascades to
siblings.

---

## Dependency choice: first-party JSON-RPC/MCP layer

Nyanform deliberately implements its JSON-RPC 2.0 + MCP lifecycle layer
**first-party** instead of using `hermes_mcp` (or similar high-level SDKs).
The reasoning:

**Nyanform is a proxy/interceptor.** Its core job is transparent JSON-RPC
passthrough. A client sends `initialize`, `notifications/initialized`,
`tools/list`, `tools/call`, prompts, resources, completions, pings — Nyanform
must forward every message type it does not actively rewrite, byte-for-byte
where possible, while still rewriting the small subset (`tools/list`,
`tools/call`) that requires schema projection or argument repair.

**High-level SDK DSLs fight this.** `hermes_mcp`'s `Server`/`Client` macros
are opinionated toward concrete tool registration: you declare named tools
with handler functions. That model is great for authoring a server from
scratch, but it is the wrong shape for a proxy that must forward arbitrary
methods it has never seen and never wants to know about. Adopting such a DSL
would force either (a) parsing every JSON-RPC message into the SDK's
typed tool registry (expensive, lossy, and unnecessary) or (b) maintaining a
parallel "raw passthrough" path that bypasses the SDK anyway.

**The first-party layer is small and focused.** `Nyanform.Protocol.Message`
parses and encodes JSON-RPC frames; `Nyanform.Protocol.Lifecycle` handles
the MCP initialize handshake and protocol revision negotiation;
`Nyanform.Protocol.ErrorCodes` defines the standard JSON-RPC error codes.
Everything else is transport.

**Transport libraries are reused, not reinvented:**

- **Bandit + Plug** drives the downstream HTTP server (`DownstreamHttp` /
  `HttpPlug`). Bandit is a pure-Elixir HTTP/1.1 server that integrates
  cleanly with Plug.
- **Req** drives the upstream HTTP client inside `UpstreamShrine`.
- **Erlang ports** (`:spawn_executable`) drive stdio both upstream and
  downstream, with line-delimited JSON-RPC framing on stdin/stdout and
  diagnostics on stderr.

No Phoenix, no Ecto, no database, no LLM. The only runtime data is the
in-memory session registry and the canonical schema structs compiled on
demand.

---

## The schema pipeline

Schema compilation is pure functional data transformation. There is no
GenServer wrapping the pure functions; the pipeline is a series of
`with` steps inside `Nyanform.Schema.Pipeline.compile/2`.

The eight stages, in order:

1. **Parse** — `Nyanform.Schema.Parser.parse/4` walks the raw JSON term and
   builds a `Scroll` tree, choosing the `kind` for each node (`:object`,
   `:array`, `:string`, `:integer`, `:number`, `:boolean`, `:null`, `:enum`,
   `:const`, `:union`, `:intersection`, `:ref`, `:any`, `:never`,
   `:unknown`). The parser enforces `max_schema_depth`.
2. **Structural validation** — invalid nodes (non-map, non-list branches,
   malformed enums, etc.) return a `ValidationError` with the offending
   path. This happens inline during parsing.
3. **Canonicalization** — `Nyanform.Schema.Canonicalizer.canonicalize/1`
   walks the parsed tree, deduplicates `required` arrays, nilifies empty
   property maps, strips unsupported string formats, and marks recursive
   nodes.
4. **Reference analysis** — `Nyanform.Schema.Reference` resolves `$ref`
   targets against `$defs` / `definitions`, detects cycles with
   `detect_cycles/2`, and bounds traversal with `max_reference_depth`.
   Recursive references are marked but not inlined; the digest reflects
   the canonical shape without infinite expansion.
5. **Profile projection** — `Nyanform.Profile.Projector.project/3` walks the
   canonical `Scroll` against a compatibility profile and emits a projected
   JSON-Schema-shaped map plus omens describing every transformation. This
   stage is what produces client-specific dialects.
6. **Loss analysis** — during projection, each transformation is classified
   by severity (`:exact`, `:normalized`, `:lossy`, `:rejected`). See
   [diagnostics.md](diagnostics.md).
7. **Deterministic serialization** —
   `Nyanform.Schema.Serializer.to_canonical_term/1` strips non-semantic
   fields (`description`, `title`, `default`, `examples`, `raw`, `path`),
   sorts map keys and list entries, and produces a stable Erlang term.
8. **Digest calculation** — `Serializer.digest/1` runs
   `:crypto.hash(:sha256, ...)` over the canonical term and base16-encodes
   the result. The digest is the canonical fingerprint used by
   `nyanform snapshot` and `nyanform check` for regression detection.

`Pipeline.compile_idempotent/1` runs the pipeline twice (once on the raw
input, once on the resulting `Scroll`) and asserts the two digests match,
guarding against non-idempotent transformations.

---

## Session lifecycle

`Nyanform.Session.Thread` is a `GenServer` that owns exactly one upstream
connection. One session thread maps to one logical MCP session, identified
by a session ID registered in `Nyanform.Session.Registry`.

The thread:

- **Owns one upstream connection.** On `init/1` it starts an
  `UpstreamShrine` GenServer (stdio port or HTTP client) and performs the
  MCP `initialize` handshake. The upstream process is linked; if it exits,
  the thread terminates and the dynamic supervisor may restart it.
- **Intercepts `tools/list`.** The thread fetches the upstream tool list
  via `UpstreamShrine.list_tools/1`, builds a `ToolGrimoire` (which
  sanitizes names, deduplicates aliases, and compiles each schema), and
  projects each entry against the active profile before replying.
- **Intercepts `tools/call`.** The thread resolves the incoming alias back
  to the original tool name via `ToolGrimoire.resolve_origin/2`, repairs
  arguments through `RewriteTalisman.repair/2` (e.g. unwrapping JSON-string
  arguments that clients serialize incorrectly), and forwards the call to
  the upstream under the original name.
- **Passes through everything else transparently.** Any request that is not
  `initialize`, `tools/list`, or `tools/call` is forwarded verbatim to the
  upstream. Notifications, responses, and errors are forwarded as-is.
  Nyanform never invents methods or rewrites results for methods it does
  not understand.

On `terminate/2`, the thread stops the upstream process, closing the port
or HTTP session cleanly.

Session IDs are 16-character hex strings derived from
`:crypto.strong_rand_bytes/1`. The HTTP plug accepts a client-provided
`mcp-session-id` header and reuses the corresponding thread, enabling
stateful Streamable HTTP sessions.

---

## Module map

| Module | Responsibility |
|--------|----------------|
| `Nyanform.Schema.Scroll` | Canonical JSON-Schema struct and its 15 kinds. |
| `Nyanform.Schema.Parser` | Stage 1-2: raw JSON → `Scroll` tree with depth limiting. |
| `Nyanform.Schema.Canonicalizer` | Stage 3: normalize required, drop unsupported formats, mark recursion. |
| `Nyanform.Schema.Reference` | Stage 4: resolve `$ref`, detect cycles, bound depth. |
| `Nyanform.Schema.Serializer` | Stages 7-8: deterministic term + SHA-256 digest. |
| `Nyanform.Schema.Pipeline` | Orchestrates all eight stages; exposes `compile/1,2` and `compile_idempotent/1`. |
| `Nyanform.Schema.ValidationError` | Structured error with code and path. |
| `Nyanform.Profile.Constellation` | Declarative compatibility profile struct. |
| `Nyanform.Profile.Builtins` | The six built-in profiles (canonical, claude, gemini, openai_strict, vscode, passthrough). |
| `Nyanform.Profile.Loader` | Loads a profile, optionally applying overrides; validates. |
| `Nyanform.Profile.Projector` | Stage 5-6: projects a canonical `Scroll` against a profile. |
| `Nyanform.Diagnostic.Omen` | Diagnostic struct with four severities. |
| `Nyanform.Diagnostic.Codes` | Catalog of all `NYA-*` codes with category, severity, summary. |
| `Nyanform.Report.CompatibilityResult` | Aggregate result for one profile across all tools. |
| `Nyanform.Report.Terminal` | Human-readable table renderers. |
| `Nyanform.Report.Json` | JSON renderers for `inspect` and `matrix`. |
| `Nyanform.Report.JUnit` | JUnit XML renderer for CI consumption. |
| `Nyanform.Report.Sarif` | SARIF 2.1.0 renderer for GitHub Code Scanning. |
| `Nyanform.Report.Renderer` | Format dispatch (`terminal`/`json`/`junit`/`sarif`). |
| `Nyanform.Report.Table` | Shared ASCII table layout used by the terminal renderer. |
| `Nyanform.Protocol.Message` | JSON-RPC 2.0 frame parse/encode. |
| `Nyanform.Protocol.ErrorCodes` | Standard JSON-RPC error code constants. |
| `Nyanform.Protocol.Lifecycle` | MCP initialize handshake and revision negotiation. |
| `Nyanform.Transport.UpstreamShrine` | GenServer owning one upstream stdio port or HTTP client. |
| `Nyanform.Transport.DownstreamStdio` | Line-delimited JSON-RPC loop on stdin/stdout. |
| `Nyanform.Transport.DownstreamHttp` | Bandit-based HTTP server hosting `HttpPlug`. |
| `Nyanform.Transport.HttpPlug` | Plug router handling `POST /` for MCP requests. |
| `Nyanform.Session.Thread` | GenServer owning one session: intercept, project, forward. |
| `Nyanform.ToolGrimoire` | Builds alias map, sanitizes names, deduplicates collisions. |
| `Nyanform.RewriteTalisman` | Repairs client arguments; redacts secrets in diagnostics. |
| `Nyanform.ClientFamiliar` | Detects which profile to use from `clientInfo`. |
| `Nyanform.CLI` | Entry point: `serve`, `inspect`, `matrix`, `snapshot`, `check`, `doctor`. |
| `Nyanform.Config.Loader` | Loads and validates `nyanform.json`. |
| `Nyanform.Limits` | Runtime resource limits (message size, depth, timeouts). |
| `Nyanform.Application` | OTP application and supervisor tree. |
| `Mix.Tasks.Nyanform` | Mix task wrapping the CLI. |
| `Mix.Tasks.Nyanform.NoComments` | Custom quality gate: forbids comments and doc attributes. |
