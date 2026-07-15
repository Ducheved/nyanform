# Changelog

All notable changes to Nyanform are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The repository has no published version tag or GitHub Release yet, so the
current work remains under `Unreleased`. The `0.1.0` value in `mix.exs` is
package metadata, not evidence of a published release.

## [Unreleased]

### Added

- A local-first MCP proxy with downstream and upstream stdio and HTTP
  transports, per-session upstream ownership, JSON-RPC passthrough, and
  interception of `tools/list` and `tools/call`.
- A canonical JSON Schema pipeline with parsing, canonicalization, bounded
  local-reference traversal, deterministic serialization, and canonical
  digests.
- Declarative built-in compatibility profiles for canonical, Claude, Gemini,
  OpenAI strict mode, VS Code, and passthrough behavior. These profiles are
  Nyanform-maintained compatibility hypotheses rather than vendor guarantees.
- Structured diagnostics and terminal, JSON, JUnit, and SARIF matrix reports.
- CLI commands for serving the proxy, inspecting an upstream, running the
  compatibility matrix, writing and checking snapshots, and reporting local
  runtime/configuration information with `doctor`.
- Configuration loading, profile overrides, tool-name aliasing, argument
  repair, origin checks for downstream HTTP, and isolated child-process
  environments.
- Mix quality aliases, tests, an escript build, a Docker image, and GitHub
  Actions jobs for quality, Dialyzer, escript smoke tests, and Docker smoke
  tests.

### Changed

- Profile projection and strict-policy handling now keep acceptance and
  diagnostic severity aligned with the emitted schema.
- OpenAI strict projection now preserves nested `anyOf`, local `$defs`/`$ref`,
  nested definitions, and nullable optional enums while rejecting unsupported
  root shapes and constructs explicitly.
- Paginated `tools/list` requests forward cursors, retain aliases from prior
  pages, and reuse entries and aliases when a page is requested again. Offline
  CLI commands also consume every page.
- Malformed modeled schema values and tool envelopes reject only the affected
  tool instead of raising while the catalog is built. Non-list catalog results
  return controlled errors.
- Required names that would be lost by a profile's full-`required` rewrite and
  dangling local JSON Pointer references found within the bounded traversal now
  reject the affected projection with dedicated diagnostics.
- Normalized profiles now reject retained unmodeled schema keywords instead of
  dropping them silently; passthrough remains available for constructs such as
  `prefixItems`.
- Canonical projection preserves JSON Schema boolean values, while vendor
  profiles reject them explicitly instead of substituting object schemas.
- Stdio shutdown uses an upstream `ping` boundary before draining server
  messages written before the ping response. Later notifications remain
  outside that shutdown boundary.
- Snapshot comparison accounts for input and output schemas and reports tool
  description-only changes separately from semantic schema changes.
- Invalid upstream environment configuration errors no longer echo the
  supplied values.

### Security

- Incoming JSON-RPC frames, schema recursion, local-reference traversal, tool
  catalog size, matrix concurrency, downstream HTTP bodies, and upstream
  request duration have explicit bounds in their active code paths.
- Upstream stdio commands are launched directly with Erlang ports, without a
  shell, and receive only a minimal system environment plus allowlisted and
  explicitly configured variables.
- Snapshot files do not contain tool-call arguments, but they do preserve raw
  server metadata, tool descriptions, and schemas. Review them for secrets in
  descriptions, defaults, examples, annotations, or vendor extensions before
  publishing or committing them.
