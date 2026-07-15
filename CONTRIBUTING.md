# Contributing to Nyanform

Thanks for your interest in contributing. This guide covers development
setup, the quality gates every change must pass, and the test
conventions.

## Development setup

Nyanform targets **Elixir 1.20** and **OTP 29** (declared in `mix.exs` as
`elixir: "~> 1.18"` and `erlang: "~> 27"`; the CI matrix pins 1.20 / 29).
Older versions may work but are not tested.

```sh
git clone https://github.com/Ducheved/nyanform.git
cd nyanform
mix setup
```

`mix setup` is an alias for `deps.get` followed by `compile`. After it
finishes, verify the environment:

```sh
mix nyanform doctor
```

You should see OK for the Elixir version, configuration, profile catalog,
and protocol support.

## Running Nyanform locally

```sh
mix nyanform inspect --stdio-command node --stdio-arg test/fixtures/mcp_server.js
mix nyanform matrix   --stdio-command node --stdio-arg test/fixtures/mcp_server.js
```

Or build the standalone escript:

```sh
MIX_ENV=prod mix escript.build
./nyanform serve --stdio-command node --stdio-arg server.js
```

## Quality gates

Every pull request must pass `mix ci`. Run it locally before pushing:

```sh
mix ci
```

`mix ci` is an alias that runs:

1. `mix format --check-formatted` — code must be formatted with the
   project's `.formatter.exs` (line length 98, no trailing commas).
2. `mix compile --warnings-as-errors` — any compiler warning fails the
   build.
3. `mix nyanform.no_comments` — the custom no-comments gate (see below).
4. `mix credo --strict` — static analysis with all checks enabled.
5. `mix test --include property:true` — unit, integration, and property
   tests.
6. `mix dialyzer` — success-typing analysis. The first run builds the PLT
   under `priv/plts/` and is slow; subsequent runs are cached.

For a faster feedback loop during development, use `mix quality`, which
runs steps 1-4 followed by the regular `mix test` suite, without property
tests or Dialyzer:

```sh
mix quality
```

### The no-comments rule

Nyanform forbids comments and documentation attributes in first-party
source. This is enforced by `mix nyanform.no_comments`, which scans:

- Elixir files in `lib/`, `config/`, `test/`, `priv/`, `rel/` for inline
  `#` comments and for `@moduledoc`, `@doc`, `@typedoc` attributes.
- Shell scripts, YAML files, Dockerfiles, and files under `.github/` for
  `#` comments.

Shebang lines (`#!`) on line 1 of shell scripts are allowed. Everything
else is rejected. Documentation lives in:

- `docs/*.md` for architecture, schema, profiles, diagnostics, security,
  and operational guides.
- `README.md`, `CHANGELOG.md`, `SECURITY.md`, `CONTRIBUTING.md`, and
  `CODE_OF_CONDUCT.md` for repository deliverables.

If you find yourself wanting to explain *why* a piece of code exists, put
that explanation in the relevant `docs/` file and link to it from the PR
description. See [docs/quality-exceptions.md](docs/quality-exceptions.md)
for the rationale and the list of Credo exceptions.

### Credo configuration

`.credo.exs` runs in strict mode. A handful of checks are adjusted; see
[docs/quality-exceptions.md](docs/quality-exceptions.md) for the full
list and rationale. The short version:

- `ModuleDoc` is disabled because every module legitimately lacks
  `@moduledoc`.
- `Nesting` is set to 3 to accommodate protocol dispatch.
- `StructFieldAmount` is set to 40 because the `Scroll` struct uses 34
  fields.

## Test conventions

Tests live in `test/` and mirror the `lib/` structure:

```
test/
  nyanform/
    schema/
      pipeline_smoke_test.exs
      property_test.exs
    profile/
      projector_test.exs
    protocol/
      message_test.exs
    report/
      renderer_test.exs
    transport/
      stdio_proxy_test.exs
    client_familiar_test.exs
    cli_test.exs
    rewrite_talisman_test.exs
    tool_grimoire_test.exs
  mix/
    tasks/nyanform/no_comments_test.exs
  fixtures/
    mcp_server.js
```

Conventions:

- One `_test.exs` file per module under test.
- Unit tests use `ExUnit.Case`. Property tests use `ExUnitProperties`
  (from `stream_data`) and are tagged `@tag :property`; they are excluded
  by default (`test/test_helper.exs` does `ExUnit.start(exclude: [:property])`)
  and run with `mix test --include property:true` or `mix test.all`.
- The MCP server fixture at `test/fixtures/mcp_server.js` is a real
  stdio MCP server used by the transport and CLI tests for end-to-end
  validation. It must remain dependency-free (plain Node.js, no npm
  install) so CI can run it without setup.
- `config/test.exs` shortens `request_timeout_ms` to 5 seconds so hung
  tests fail fast.

Run the full suite including property tests:

```sh
mix test.all
```

## Sending a pull request

1. Fork the repository and create a feature branch from `main`.
2. Make your change. Add or update tests under `test/`.
3. Run `mix ci` locally and ensure it passes.
4. Update `CHANGELOG.md` under the `[Unreleased]` section with a one-line
   summary of user-visible changes.
5. Update or add `docs/` files if your change affects architecture,
   schema handling, profiles, diagnostics, security, or operations.
6. Open a pull request using the PR template (`.github/PULL_REQUEST_TEMPLATE.md`).
   Reference any related issue.

Pull requests that touch Elixir files but do not pass `mix ci` will be
flagged by CI and cannot be merged.

## Code style

- Line length 98. No trailing commas in lists, maps, or keyword lists
  (configured in `.formatter.exs`).
- No comments and no doc attributes in Elixir source.
- Prefer pure functions and data transformation over processes. The
  schema compiler is entirely pure; only the session, transport, and
  application layers use GenServers.
- Prefer pattern matching and `with` over nested `case`.
- Structs carry `@type t :: %__MODULE__{...}` definitions for Dialyzer.

## License

By contributing, you agree that your contributions are licensed under the
MIT License, as described in [LICENSE](LICENSE).
