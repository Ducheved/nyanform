# Nyanform build status

Status: the implementation is assembled in the repository and remains
unreleased. A quality result belongs to a specific commit and CI run; this file
does not freeze a test count or claim that the current worktree has passed every
gate.

## Goal

Nyanform inspects and adapts MCP tool schemas through a local-first proxy and
schema compiler. It sits between an MCP client and an MCP server, builds a
canonical representation of upstream tool schemas, and projects a selected
compatibility dialect while reporting detected loss.

## Architecture decisions represented in code

- The proxy owns a focused JSON-RPC 2.0 and MCP lifecycle layer so methods that
  Nyanform does not intercept can pass through without being modeled as local
  tools.
- Bandit and Plug provide downstream HTTP, Req provides upstream HTTP, and
  Erlang ports provide upstream stdio without a shell.
- Schema compilation and projection are data transformations. Processes are
  used for application supervision, sessions, transports, and concurrent
  matrix work.
- Compatibility profiles are declarative Nyanform policy. They must be kept
  separate from claims about official vendor support.

## Implemented workstreams

- Mix application scaffold, supervision, configuration, and limits.
- Canonical schema representation, parser, canonicalizer, local-reference
  analysis, serializer, and digest.
- Built-in profiles, profile overrides, projection, and structured diagnostics.
- Terminal, JSON, JUnit, and SARIF reporting.
- `serve`, `inspect`, `matrix`, `snapshot`, `check`, and `doctor` commands.
- MCP lifecycle and JSON-RPC framing over stdio and HTTP transports.
- Session management, paginated tool catalogs with stable cross-page aliases,
  argument repair, and client profile detection.
- Unit, property, transport, session, CLI, and quality-gate tests.
- Escript and Docker builds plus GitHub Actions checks.

## Release readiness checks

Before publishing a first version, verify the exact commit rather than relying
on this status document:

1. Run `mix ci`.
2. Build the escript and run the fixture-backed CLI and stdio proxy smoke tests.
3. Build the Docker image and run its `--help` smoke test.
4. Review built-in profile assumptions against current client behavior and
   clearly label any behavior that is not backed by official documentation.
5. Review generated snapshots and reports for sensitive raw schema metadata.
6. Publish a tag and release only after the intended artifact has been tested.

The repository CI performs these checks in separate jobs where applicable.
Repository branch rules, release publication, and private security intake are
hosting settings and are not guaranteed by the files in this repository.
