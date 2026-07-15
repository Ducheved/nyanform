## Summary

A one- or two-sentence description of what this pull request changes.

## Motivation

Why this change is needed. Link any related issues
(`Closes #123`, `Refs #456`).

## Changes

-
-
-

## Type of change

Check the relevant items:

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (would cause existing projections, digests, or
      CLI behavior to change)
- [ ] Documentation only
- [ ] Refactor / internal cleanup

## Quality gates

This pull request is not ready for review until all of the following pass
locally:

- [ ] `mix format --check-formatted`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix nyanform.no_comments`
- [ ] `mix credo --strict`
- [ ] `mix test`
- [ ] `mix test --include property:true` (if the change touches the
      schema compiler, projector, or argument repair)
- [ ] `mix dialyzer`

Or, equivalently: `mix ci`.

## Tests

Describe the tests you added or updated. If you changed the schema
compiler or projector, mention whether property tests cover the new
behavior.

## Documentation

- [ ] Updated `docs/` files affected by this change.
- [ ] Updated `CHANGELOG.md` under `[Unreleased]`.
- [ ] Updated `README.md` if the user-facing surface changed.
- [ ] No comments or `@moduledoc` / `@doc` / `@typedoc` attributes added
      to Elixir source.

## Schema or digest impact

If this change alters how schemas are canonicalized or projected, note
that digests may change. Existing snapshots in `_snapshots/` may need to
be regenerated. If so, explain why the change is intentional.
