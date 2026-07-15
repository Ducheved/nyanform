# Nyanform — Build Plan

Status: complete — all quality gates pass.

## Goal

One MCP server works everywhere. A local-first proxy + schema compiler that
sits between an MCP client and an MCP server, compiles upstream tool schemas
into a canonical representation, and projects a compatible dialect per client.

## Architecture decisions

* Proxy/interceptor role requires transparent JSON-RPC passthrough. The
  high-level SDK DSLs (hermes_mcp `Server`/`Client` macros) are opinionated
  toward concrete tool registration and fight the interceptor pattern.
* Nyanform owns a thin, focused JSON-RPC 2.0 + MCP lifecycle layer over the
  standard library plus transport libs (Bandit/Plug downstream HTTP, Req
  upstream HTTP, Erlang ports for stdio). Rationale in `docs/architecture.md`.
* Schema compilation is pure data: no GenServer wrapping pure functions.

## Vertical slices (all complete)

1. [scaffold] mix project, config, formatter, application
2. [compiler] canonical schema representation + parser + canonicalizer + refs + digest
3. [profiles] compatibility profiles as declarative data + projection
4. [diagnostics] omens + report renderers (terminal/JSON/JUnit/SARIF)
5. [cli] inspect/matrix/snapshot/check/doctor/serve
6. [protocol] JSON-RPC framing + MCP lifecycle
7. [transports] stdio + Streamable HTTP, downstream + upstream
8. [catalog] tool grimoire (alias mapping) + argument repair talisman
9. [serve] serve command + client familiar (profile detection)
10. [fixtures] deterministic fixture servers/clients + golden outputs
11. [quality] no-comments checker + aliases
12. [tests] canonicalization/profile/property/args/protocol/transports/CLI
13. [docs] README + docs/* + repo deliverables
14. [release] release + Dockerfile + GitHub Actions
15. [validate] final end-to-end suite

## Quality results

- format: PASS
- compile --warnings-as-errors: PASS
- no-comments checker: PASS (0 violations)
- credo --strict: PASS (0 failures)
- dialyzer: PASS (documented false positives suppressed)
- tests: 118 passed (6 properties, 112 tests)
- release: built (40 MB tar.gz)

## Test categories

- Canonicalization: 15 tests
- Profile projection: 22 tests
- Property-based: 6 properties
- Arguments/repair: 13 tests
- Protocol messages: 11 tests
- Client familiar: 9 tests
- Tool grimoire: 7 tests
- Report rendering: 10 tests
- No-comments checker: 7 tests
- Stdio proxy integration: 6 tests
- CLI integration: 14 tests
