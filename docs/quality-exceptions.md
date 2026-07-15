# Quality configuration exceptions

`mix quality` and `mix ci` run Credo in strict mode together with formatting,
warning-free compilation, the repository no-comments task, and tests. `mix ci`
also runs Dialyzer. Whether a particular revision passes is established by the
command or its CI run, not by this document.

## Credo configuration

The following adjustments are present in `.credo.exs`.

### `Readability.ModuleDoc` disabled

```elixir
{Credo.Check.Readability.ModuleDoc, false}
```

First-party Elixir source intentionally omits `@moduledoc`, `@doc`, and
`@typedoc`. The custom `mix nyanform.no_comments` task rejects those attributes,
so enabling Credo's module-documentation requirement would conflict with the
repository's source policy. User and architecture documentation lives in
Markdown instead.

### `Refactor.Nesting` maximum 3

```elixir
{Credo.Check.Refactor.Nesting, max_nesting: 3}
```

The threshold permits the existing protocol and schema dispatch shapes while
still flagging deeper nesting. Representative code includes
`Session.Thread.handle_call/3`, `Profile.Projector.project_scroll/4`, and
`Schema.Parser.parse/4`. The setting is a lint threshold, not a claim that every
function reaches or requires depth 3.

### `Warning.StructFieldAmount` maximum 40

```elixir
{Credo.Check.Warning.StructFieldAmount, max_fields: 40}
```

`Nyanform.Schema.Scroll` currently has 35 fields:

- 2 identity fields: `kind` and `path`.
- 5 metadata fields.
- 6 object fields.
- 6 array fields.
- 4 string fields.
- 2 enum/const fields.
- 5 numeric fields.
- 3 branch/reference fields.
- 1 definitions map.
- 1 raw fallback field.

The limit therefore leaves five fields of headroom. The large struct is the
single canonical representation used by the parser, canonicalizer, projector,
and serializer; splitting it solely to satisfy the default Credo field count
would add dispatch and conversion without changing the modeled data.

### Other configured checks

```elixir
{Credo.Check.Warning.ExpensiveEmptyEnumCheck, files: %{excluded: ["test/**/*"]}}
{Credo.Check.Warning.LazyLogging, false}
{Credo.Check.Warning.IExPry, []}
{Credo.Check.Warning.IoInspect, []}
{Credo.Check.Warning.UnusedEnumOperation, []}
{Credo.Check.Warning.BoolOperationOnSameValues, []}
```

- `ExpensiveEmptyEnumCheck` is excluded under `test/`; production source is
  still checked.
- `LazyLogging` is explicitly disabled. The current application code configures
  logger levels but has no normal `Logger.debug/info/warning/error` emission
  sites for this rule to optimize. Revisit the exception if runtime logging is
  added.
- `IExPry` and `IoInspect` remain enabled with their default options so stray
  debugging calls are reported.
- `UnusedEnumOperation` and `BoolOperationOnSameValues` remain enabled with
  their default options.

## The no-comments task

`mix nyanform.no_comments` discovers Elixir files under `lib/`, `config/`,
`test/`, `priv/`, and `rel/`. It rejects inline `#` comments and the three
documentation attributes listed above, while allowing a shell shebang on line
one.

For non-Elixir content, the task checks supported `.sh`, `.yml`, `.yaml`, and
Dockerfile paths discovered under `scripts`, the root Docker artifacts, and
`.github`. It only treats full comment lines as violations in those formats.
Markdown files are not checked by this task.

The scanner is a repository convention check, not a general parser or a
security control. When it reports a false positive or misses a syntax form,
fix the checker and add a focused task test instead of documenting an invisible
exception.

## Dialyzer

`mix ci` runs `mix dialyzer`, with PLTs under `priv/plts/` and
`list_unused_filters: true`. `.dialyzer_ignore.exs` currently contains an empty
list, so no warning is suppressed there.

If a future warning truly requires a filter, first confirm it cannot be fixed
with a more accurate type, contract, or control flow. Any added filter should
be as narrow as possible, documented here, and kept visible to Dialyzer's
unused-filter check.
