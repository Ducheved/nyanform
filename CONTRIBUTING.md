# Contributing to Nyanform

Thanks for your interest in contributing. This guide covers development setup,
the repository quality gates, and the test conventions used by the current
codebase.

## Development setup

`mix.exs` declares Elixir `~> 1.18` and an Erlang/OTP `~> 27` project value. The
GitHub Actions workflow currently exercises Elixir 1.20 with OTP 29; that CI
pair is the checked-in workflow baseline, not a narrower release claim.

```sh
git clone https://github.com/Ducheved/nyanform.git
cd nyanform
mix setup
```

`mix setup` fetches dependencies and compiles the project. You can then inspect
the local runtime and application catalog:

```sh
mix nyanform doctor
```

`doctor` reports the running Elixir version and checks that the protocol
revision and expected built-in profiles are present. It does not currently
enforce the Elixir/OTP version constraints and does not print the Nyanform
source revision or release provenance.

## Running Nyanform locally

```sh
mix nyanform inspect --stdio-command node --stdio-arg test/fixtures/mcp_server.js
mix nyanform matrix --stdio-command node --stdio-arg test/fixtures/mcp_server.js
```

To build the standalone escript:

```sh
MIX_ENV=prod mix escript.build
./nyanform serve --stdio-command node --stdio-arg server.js
```

## Quality gates

Run the full repository gate before requesting review:

```sh
mix ci
```

The `mix ci` alias runs:

1. `mix format --check-formatted`
2. `mix compile --warnings-as-errors`
3. `mix nyanform.no_comments`
4. `mix credo --strict`
5. `mix test --include property:true`
6. `mix dialyzer`

The first Dialyzer run may need to build PLTs under `priv/plts/`. For a faster
feedback loop, `mix quality` runs formatting, warning-free compilation, the
no-comments checker, Credo, and the regular test suite. It omits Dialyzer and
the property-tagged tests excluded by `test/test_helper.exs`.

### The no-comments rule

`mix nyanform.no_comments` scans first-party Elixir files under `lib/`,
`config/`, `test/`, `priv/`, and `rel/` for inline comments and for
`@moduledoc`, `@doc`, and `@typedoc` attributes. It also checks supported shell,
YAML, and Dockerfile paths, including eligible files under `.github/`, for
comment lines. A shell shebang on line one is allowed. Markdown is not part of
that non-Elixir scan.

User-facing and architectural explanations belong in Markdown. See
[docs/quality-exceptions.md](docs/quality-exceptions.md) for the current Credo
adjustments and no-comments rationale.

### Formatter and Credo configuration

`.formatter.exs` sets a line length of 98 and disables trailing commas.
`.credo.exs` runs in strict mode with documented adjustments, including:

- `Readability.ModuleDoc` disabled to match the no-doc-attributes rule.
- `Refactor.Nesting` capped at depth 3.
- `Warning.StructFieldAmount` capped at 40 because the canonical `Scroll`
  struct currently has 35 fields.

## Test conventions

Tests live under `test/`, with unit and integration coverage grouped by feature
area. The suite includes schema and profile behavior, configuration, protocol,
session and transport behavior, CLI commands, reports, argument repair, tool
catalog behavior, and the no-comments task.

- Unit and integration tests use `ExUnit.Case`.
- Property tests use `ExUnitProperties`, are tagged `:property`, and are
  excluded by the default `ExUnit.start(exclude: [:property])` configuration.
- Run the regular suite with `mix test` and include property tests with
  `mix test --include property:true` or `mix test.all`.
- JavaScript fixtures under `test/fixtures/` are dependency-free Node.js
  programs used by transport and CLI tests.
- `config/test.exs` uses a shorter upstream request timeout so stalled test
  interactions fail sooner.

Do not rely on a test count written in documentation; use the output from the
exact commit being reviewed.

## Sending a pull request

1. Create a feature branch from `main`.
2. Make the smallest change that solves the issue and add or update relevant
   tests.
3. Run the appropriate focused tests, then `mix ci`.
4. Update `CHANGELOG.md` under `Unreleased` for user-visible changes.
5. Update affected documentation when behavior, architecture, profiles,
   diagnostics, security, or operations change.
6. Open a pull request using `.github/PULL_REQUEST_TEMPLATE.md` and include the
   verification results for the tested commit.

The checked-in workflow reports failures on pushes to and pull requests against
`main`. Whether a failure prevents merging depends on GitHub repository rules;
the workflow file itself does not configure branch protection.

## Code style

- Follow `.formatter.exs` and the existing module style.
- Do not add comments or documentation attributes to first-party Elixir source.
- Prefer direct data transformations and focused functions over unnecessary
  processes or abstractions.
- Preserve existing public types and update them when behavior changes.

## License

By contributing, you agree that your contributions are licensed under the MIT
License described in [LICENSE](LICENSE).
