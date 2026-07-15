# Changelog

All notable changes to Nyanform are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-14

Initial public release.

### Added

- **OTP application** with a supervision tree: `Registry` for sessions,
  `DynamicSupervisor` for `Session.Thread` processes, and a
  `Task.Supervisor` for concurrent matrix compilation.
- **Schema compiler** (`Nyanform.Schema.*`): an eight-stage pipeline
  (parse, structural validation, canonicalization, reference analysis,
  profile projection, loss analysis, deterministic serialization, digest
  calculation) that turns arbitrary JSON Schemas into the canonical
  `Scroll` struct. The pipeline is pure functional data transformation
  and is idempotent (`Pipeline.compile_idempotent/1`).
- **Canonical `Scroll` struct** with 15 kinds (object, array, string,
  integer, number, boolean, null, enum, const, union, intersection, ref,
  any, never, unknown) and 34 fields covering the JSON Schema surface.
- **Reference handling**: `$ref` resolution against `$defs`/`definitions`,
  cycle detection (`Reference.detect_cycles/2`), and bounded depth
  traversal (`max_reference_depth`).
- **Deterministic digests**: `Serializer.digest/1` produces a stable
  SHA-256 fingerprint of the canonical form, used by `snapshot` and
  `check` for regression detection.
- **Six compatibility profiles** (`Nyanform.Profile.Builtins`):
  `canonical`, `claude`, `gemini`, `openai_strict`, `vscode`,
  `passthrough`. Each is declarative data; a shared projector
  (`Nyanform.Profile.Projector`) compiles a canonical `Scroll` against
  any profile and emits structured diagnostics.
- **Profile overrides** via `Nyanform.Profile.Loader.load/2`, with
  validation.
- **Diagnostics system** (`Nyanform.Diagnostic.*`): the `Omen` struct
  with four severities (`exact`, `normalized`, `lossy`, `rejected`) and a
  catalog of 30 diagnostic codes across six categories (schema, profile,
  alias, transport, argument, config).
- **Report renderers**: terminal tables (`Report.Terminal`, `Report.Table`),
  JSON (`Report.Json`), JUnit XML (`Report.JUnit`), and SARIF 2.1.0
  (`Report.Sarif`) for GitHub Code Scanning.
- **JSON-RPC 2.0 + MCP protocol layer** (`Nyanform.Protocol.*`): message
  framing, standard error codes, and the MCP initialize handshake with
  protocol revision `2025-11-25` (and `2025-06-18` fallback).
- **Transports** (`Nyanform.Transport.*`):
  - Upstream stdio via Erlang ports (`:spawn_executable`, no shell).
  - Upstream HTTP via `Req`.
  - Downstream stdio (line-delimited JSON-RPC).
  - Downstream HTTP via `Bandit` + `Plug` (`HttpPlug`), default-bound to
    `127.0.0.1`.
- **Session lifecycle** (`Nyanform.Session.Thread`): one GenServer per
  session, owning one upstream connection; intercepts `tools/list` and
  `tools/call`, passes through all other JSON-RPC transparently.
- **Tool catalog** (`Nyanform.ToolGrimoire`): builds an alias map,
  sanitizes tool names per profile, deduplicates collisions with
  deterministic SHA-256 suffixes.
- **Argument repair** (`Nyanform.RewriteTalisman`): repairs JSON-string
  arguments that clients serialize incorrectly, plus secret redaction
  (`redact_secrets/2`) for safe diagnostic emission.
- **Client auto-detection** (`Nyanform.ClientFamiliar`): maps
  `clientInfo.name` to a profile (`--profile auto`).
- **CLI** (`Nyanform.CLI`) with six commands: `serve`, `inspect`,
  `matrix`, `snapshot`, `check`, `doctor`.
- **Configuration loading** (`Nyanform.Config.Loader`): `nyanform.json`
  parsing and validation.
- **Resource limits** (`Nyanform.Limits`): message size, schema depth,
  reference depth, tool count, concurrency, HTTP body size, diagnostic
  count, request timeout.
- **Quality gates**:
  - `mix quality` and `mix ci` aliases.
  - Custom `mix nyanform.no_comments` task that forbids comments and
    `@moduledoc`/`@doc`/`@typedoc` attributes in Elixir source, and
    comments in shell scripts, YAML, and Dockerfiles.
  - Credo strict configuration with documented exceptions.
- **Repository deliverables**: `README.md`, `LICENSE` (MIT),
  `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1),
  `SECURITY.md`, `CHANGELOG.md`, `docs/` guides, `examples/nyanform.json`,
  `priv/nyanform.schema.json`, multi-stage `Dockerfile`,
  `docker-compose.yml`, and a GitHub Actions CI workflow.
- **Test suite**: unit tests, property tests (StreamData), transport
  end-to-end tests against a fixture MCP server, and the no-comments
  checker's own tests.

### Security

- All JSON-RPC frames are size-bounded before decoding
  (`max_message_size`, default 1 MiB).
- HTTP request bodies are size-bounded (`max_http_body_size`, default
  4 MiB).
- Schema parsing enforces `max_schema_depth` (default 64) and
  `max_reference_depth` (default 32) to defeat adversarial schemas.
- Upstream stdio processes are spawned via `:spawn_executable` (no shell)
  with explicit, operator-provided environment only.
- Downstream HTTP binds to `127.0.0.1` by default.
- Diagnostics never include raw tool arguments or environment values;
  `RewriteTalisman.redact_secrets/2` is available for any code path that
  must emit argument data.
- stdout in stdio mode is reserved exclusively for JSON-RPC frames; all
  diagnostics go to stderr.

### Dependencies

- Runtime: `jason` 1.4, `nimble_options` 1.1, `req` 0.5, `bandit` 1.5,
  `plug` 1.16, `telemetry` 1.3.
- Dev/test: `stream_data` 1.1, `credo` 1.7, `dialyxir` 1.4.
- Targets Elixir 1.20, OTP 29, MCP protocol revision 2025-11-25.

[Unreleased]: https://github.com/Ducheved/nyanform/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Ducheved/nyanform/releases/tag/v0.1.0
