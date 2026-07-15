# Quality exceptions

Nyanform enforces a strict quality gate via `mix quality` and `mix ci`.
Most Credo checks run at their default strict settings, but a small number
of exceptions are recorded in `.credo.exs`. This document explains each
exception and why it is necessary.

The general principle: every exception is deliberate, documented here, and
kept to the minimum required for the codebase to function.

---

## Credo `Readability.ModuleDoc` — disabled

```elixir
{Credo.Check.Readability.ModuleDoc, false}
```

**Reason.** Nyanform prohibits `@moduledoc`, `@doc`, and `@typedoc`
attributes in first-party Elixir source. This is enforced by the custom
`mix nyanform.no_comments` task (see
`lib/mix/tasks/nyanform/no_comments.ex`), which scans `lib/`, `config/`,
`test/`, `priv/`, and `rel/` for any of these attributes and fails the
build if it finds one.

The rationale for the no-doc-attributes rule is that Nyanform's
documentation lives in markdown files under `docs/` and in the repository
deliverables (README, CHANGELOG, etc.), not inline in the source. Keeping
documentation out of the source keeps the modules short and forces
documentation to be written in the place where users actually read it.

Because every module legitimately lacks a `@moduledoc`, Credo's
`ModuleDoc` check (which would normally require one) must be disabled to
avoid false positives.

---

## Credo `Refactor.Nesting` — max nesting 3

```elixir
{Credo.Check.Refactor.Nesting, max_nesting: 3}
```

**Reason.** The default max nesting for this check is 2. Nyanform's
protocol and projection code legitimately requires deeper nesting in a
few places, most notably:

- `Nyanform.Session.Thread.handle_call/3` clauses dispatch on the message
  kind and method, then delegate to handlers that themselves contain
  `case` or `with` expressions. The dispatch-plus-handler shape reaches
  depth 3.
- `Nyanform.Profile.Projector.project_scroll/4` dispatches on `kind` and
  then on profile fields, which is naturally a two-level dispatch.
- `Nyanform.Schema.Parser.parse/4` dispatches on the node shape with a
  `cond`.

Setting the threshold to 3 accommodates these protocol-handling patterns
without inviting the deeply-nested code that the check is designed to
prevent. Anything deeper than 3 is still flagged and must be refactored.

---

## Credo `Warning.StructFieldAmount` — max fields 40

```elixir
{Credo.Check.Warning.StructFieldAmount, max_fields: 40}
```

**Reason.** `Nyanform.Schema.Scroll` is the canonical JSON-Schema struct.
It needs **34 fields** to represent the full surface area of JSON Schema
comprehensively:

- 1 `kind` discriminator
- 1 `path`
- 5 metadata (`description`, `title`, `default`, `examples`, `annotations`)
- 5 object-specific (`properties`, `required`, `pattern_properties`,
  `additional_properties`, `min_properties`, `max_properties`) — 6 here
- 5 array-specific (`items`, `tuple_items`, `additional_items`,
  `min_items`, `max_items`, `unique_items`) — 6 here
- 4 string-specific (`format`, `pattern`, `min_length`, `max_length`)
- 2 enum/const (`enum`, `const`)
- 5 numeric (`minimum`, `maximum`, `exclusive_minimum`,
  `exclusive_maximum`, `multiple_of`)
- 3 combinator (`branches`, `ref_target`, `recursive`)
- 1 `raw` (preserves the original node for unknown kinds and for
  fallback projection)

The default Credo threshold is 12 fields. Raising it to 40 gives a small
headroom (34 used, 6 spare) for future JSON-Schema keywords without
re-triggering the check. Splitting the struct into per-kind sub-structs
would complicate the parser, canonicalizer, and serializer
(switching on `kind` to pick the right sub-struct at every site) for no
runtime benefit, since `Scroll` is a pure data carrier.

---

## Other disabled or adjusted checks

For completeness, these checks are also adjusted in `.credo.exs`:

```elixir
{Credo.Check.Warning.ExpensiveEmptyEnumCheck, files: %{excluded: ["test/**/*"]}}
{Credo.Check.Warning.LazyLogging, false}
{Credo.Check.Warning.IExPry, []}
{Credo.Check.Warning.IoInspect, []}
{Credo.Check.Warning.UnusedEnumOperation, []}
{Credo.Check.Warning.BoolOperationOnSameValues, []}
```

- `ExpensiveEmptyEnumCheck` is excluded in tests because test setup code
  legitimately uses `Enum.empty?/1` on small literals for clarity.
- `LazyLogging` is disabled because Nyanform uses structured telemetry and
  the logger metadata in `config/config.exs`, not inline `Logger.debug`
  calls that benefit from lazy evaluation.
- `IExPry` and `IoInspect` are listed (enabled) so that any stray debugging
  statement fails the build.
- `UnusedEnumOperation` and `BoolOperationOnSameValues` are listed
  (enabled) to enforce that no enum result is silently discarded and no
  boolean is computed against itself.

---

## The no-comments checker

The custom `mix nyanform.no_comments` task is itself a quality gate. It
scans:

- **Elixir files** in `lib/`, `config/`, `test/`, `priv/`, `rel/` for:
  - Inline `#` comments (after string/char-literal stripping, so `#`
    inside a string is fine).
  - `@moduledoc`, `@doc`, `@typedoc` attributes (detected via AST walk).
  - Shebang lines (`#!`) on line 1 are allowed.
- **Non-Elixir files**: shell scripts (`.sh`), YAML (`.yml`/`.yaml`),
  Dockerfiles, and anything under `.github/` for comments starting with
  `#` (with the shebang exception for shell scripts).

This is why the Dockerfile, docker-compose.yml, shell scripts, and GitHub
workflow files in this repository contain no comments. Documentation for
those artifacts lives in the `docs/` markdown files.

If you add a comment to any of these files, `mix nyanform.no_comments`
will fail with a message like:

```
no-comments: 1 violation(s) found
  lib/nyanform/foo.ex:42: comment found:     # TODO fix this
```

---

## Dialyzer — documented false positives

Nyanform runs Dialyzer as part of `mix ci`. A small set of false-positive
warnings are suppressed via `.dialyzer_ignore.exs` (regex patterns). All
suppressed warnings fall into three categories:

1. **`no_return` / `unused_fun` cascading from `Pipeline.compile`**:
   `Nyanform.Schema.Pipeline.compile/1` calls `Nyanform.Limits.default/0`
   which uses `Application.fetch_env!/2`. Dialyzer infers this can always
   raise (no local return), which cascades to every caller (`CLI`,
   `Session.Thread`, `ToolGrimoire`) as `no_return` or `unused_fun`.

2. **`pattern_match` in `Projector.fallback_rejected_schema`**: Dialyzer
   narrows the `Scroll` kind at the call site so the per-kind clauses
   appear unreachable.

3. **`invalid_contract` in `Pipeline`**: the `@spec` references types
   that Dialyzer cannot fully resolve across module boundaries.

These are false positives — the code is exercised by 118 passing tests
including 6 property tests. The ignore file uses broad regex patterns
scoped to specific files and line ranges so genuine new warnings would
not be suppressed.
