# Compatibility profiles

Compatibility profiles ("constellations") are Nyanform's declarative
description of what each MCP client accepts. The projector reads a
constellation and rewrites a canonical `Scroll` to match.

---

## Important: these are Nyanform profiles, not vendor specifications

The profiles shipped with Nyanform (`claude`, `gemini`, `openai_strict`,
`vscode`) are **Nyanform's own compatibility profiles**, reverse-engineered
from public documentation and observed client behavior. They are **not**
official specifications published by Anthropic, Google, OpenAI, or
Microsoft. Each profile struct carries a `description` field that states
this explicitly.

Vendors may change their tool-call schemas at any time. If you observe a
mismatch between Nyanform's projection and the actual client, the profile
is the thing to adjust — please open an issue or override it locally.

---

## The six built-in profiles

`Nyanform.Profile.Builtins.all/0` returns these six profiles:

| Profile | Label | Reference support | Const | Pattern props |
|---------|-------|-------------------|-------|---------------|
| `canonical` | Canonical MCP | full | yes | yes |
| `claude` | Claude Code | local only | yes | no |
| `gemini` | Gemini CLI | local only | no | no |
| `openai_strict` | OpenAI strict function tools | none | yes | no |
| `vscode` | VS Code MCP | local only | yes | no |
| `passthrough` | Passthrough | full | yes | yes |

### Per-profile matrix

The table below documents every field of `Nyanform.Profile.Constellation`.
Values are taken directly from `lib/nyanform/profile/builtins.ex`.

#### Accepted keywords

| Profile | Accepted keywords |
|---------|-------------------|
| `canonical` | type, properties, required, additionalProperties, patternProperties, items, additionalItems, minItems, maxItems, uniqueItems, description, title, default, examples, format, pattern, minLength, maxLength, enum, const, minimum, maximum, exclusiveMinimum, exclusiveMaximum, multipleOf, minProperties, maxProperties, oneOf, anyOf, allOf, $ref, $defs, definitions |
| `claude` | type, properties, required, additionalProperties, items, description, title, enum, const, minimum, maximum, exclusiveMinimum, exclusiveMaximum, multipleOf, minItems, maxItems, uniqueItems, minLength, maxLength, pattern, format, oneOf, anyOf, allOf, $ref, $defs |
| `gemini` | type, properties, required, additionalProperties, items, description, enum, format, minimum, maximum, minLength, maxLength, oneOf, anyOf, $ref, $defs |
| `openai_strict` | type, properties, required, additionalProperties, items, description, enum, const, minimum, maximum, exclusiveMinimum, exclusiveMaximum, multipleOf, minItems, maxItems, minLength, maxLength |
| `vscode` | type, properties, required, additionalProperties, items, description, title, enum, const, format, pattern, minLength, maxLength, minimum, maximum, multipleOf, oneOf, anyOf, allOf, $ref, $defs |
| `passthrough` | same as `canonical` |

#### Supported combinators

| Profile | oneOf | anyOf | allOf |
|---------|-------|-------|-------|
| `canonical` | yes | yes | yes |
| `claude` | yes | yes | yes |
| `gemini` | yes | yes | no |
| `openai_strict` | no | no | no |
| `vscode` | yes | yes | yes |
| `passthrough` | yes | yes | yes |

#### Reference support

| Profile | reference_support |
|---------|-------------------|
| `canonical` | `:full` (any `$ref`) |
| `claude` | `:local_only` (only `#/...` refs) |
| `gemini` | `:local_only` |
| `openai_strict` | `:none` |
| `vscode` | `:local_only` |
| `passthrough` | `:full` |

A ref is considered "local" when its joined target string does not contain
a `:` (i.e. no scheme). External refs are rejected even by `local_only`
profiles.

#### Nullable representation

All built-in profiles use `nullable_representation: :type_array`, meaning
nullable types are expressed as a JSON-Schema `type` array
(e.g. `["string", "null"]`). The other forms defined by the type
(`:nullable_keyword`, `:union_null`, `:unsupported`) are not used by any
built-in profile but exist for custom profiles.

#### Required / additional properties

| Profile | requires_all_properties_required | supports_additional_properties_false |
|---------|----------------------------------|--------------------------------------|
| `canonical` | no | yes |
| `claude` | no | yes |
| `gemini` | no | **no** |
| `openai_strict` | **yes** | yes |
| `vscode` | no | yes |
| `passthrough` | no | yes |

`openai_strict` requires every property to be listed in `required` (OpenAI
strict mode semantics); the projector emits a `NYA-PROFILE-001` omen when
applying this normalization. `gemini` does not support
`additionalProperties: false`, so the projector drops it and emits a
`NYA-SCHEMA-003` lossy omen.

#### Array forms

| Profile | homogeneous | tuple | no_items |
|---------|-------------|-------|----------|
| `canonical` | yes | yes | yes |
| `claude` | yes | yes | no |
| `gemini` | yes | no | no |
| `openai_strict` | yes | no | no |
| `vscode` | yes | yes | no |
| `passthrough` | yes | yes | yes |

- `homogeneous` — `items` is a single schema.
- `tuple` — `items` is an array of schemas.
- `no_items` — `type: array` with no `items` keyword.

#### Enum forms

| Profile | homogeneous | mixed | empty |
|---------|-------------|-------|-------|
| `canonical` | yes | yes | yes |
| `claude` | yes | yes | no |
| `gemini` | yes | no | no |
| `openai_strict` | yes | no | no |
| `vscode` | yes | yes | no |
| `passthrough` | yes | yes | yes |

- `homogeneous` — all enum values are the same JSON type.
- `mixed` — enum values span multiple types.
- `empty` — `enum: []`.

#### Schema depth, tool name, description length

| Profile | max_schema_depth | tool_name_pattern | max_tool_name_length | max_description_length |
|---------|------------------|-------------------|----------------------|------------------------|
| `canonical` | unlimited | `^[a-zA-Z0-9_-]+$` | unlimited | unlimited |
| `claude` | 64 | `^[a-zA-Z0-9_-]{1,64}$` | 64 | 1024 |
| `gemini` | 32 | `^[a-zA-Z][a-zA-Z0-9_-]{0,63}$` | 64 | 1024 |
| `openai_strict` | 16 | `^[a-zA-Z0-9_-]{1,64}$` | 64 | 1024 |
| `vscode` | 64 | `^[a-zA-Z0-9_.-]{1,128}$` | 128 | 2048 |
| `passthrough` | unlimited | `^[a-zA-Z0-9_-]+$` | unlimited | unlimited |

#### Const and pattern properties

| Profile | supports_const | supports_pattern_properties |
|---------|----------------|------------------------------|
| `canonical` | yes | yes |
| `claude` | yes | no |
| `gemini` | **no** | no |
| `openai_strict` | yes | no |
| `vscode` | yes | no |
| `passthrough` | yes | yes |

When `supports_const` is false (gemini), the projector demotes `const` to
a single-value `enum` and emits `NYA-PROFILE-006`. In strict mode this is
a rejection; in compatible/permissive it is a lossy rewrite.

---

## Overriding profiles through configuration

Profiles can be overridden without forking. `Nyanform.Profile.Loader.load/2`
accepts a base profile name and a map of overrides. The overridable fields
are:

- `label`, `description`
- `requires_all_properties_required`
- `accepts_additional_properties`
- `supports_additional_properties_false`
- `max_schema_depth`
- `max_tool_name_length`
- `max_description_length`
- `supports_const`
- `supports_pattern_properties`
- `integer_vs_number_distinguished`

Override keys are strings (e.g. `"supports_const": false`). Unspecified
fields inherit from the base profile.

`Loader.validate/1` checks that the profile name is a non-empty string
and that `nullable_representation` is a known form, returning a list of
errors otherwise. This is the validation surface used when loading custom
profiles from configuration.

For most deployments, picking a built-in profile and setting the policy
(`strict` / `compatible` / `permissive`) is sufficient; profile overrides
are for clients whose quirks diverge from the built-in defaults.

---

## The projection process

`Projector.project/3` walks the canonical `Scroll` recursively. For each
node it dispatches on the `kind`:

1. It builds the projected JSON-Schema map for that node.
2. It descends into children (properties, items, branches, additional
   properties), accumulating omens.
3. After the main pass, `collect_truncation_omens/3` walks the tree again
   to record description-truncation omens (`NYA-PROFILE-007`) where the
   source description exceeds `max_description_length`.
4. `policy_accepts?/2` decides whether the projection is accepted under
   the active policy.
5. `Omen.worst/1` computes the worst severity across all omens.

The return value is a map with `:schema`, `:omens`, `:accepted`, and
`:worst_severity`.

### How omens are generated

Each transformation site in the projector constructs an `Omen` via one of
the four severity constructors (`Omen.exact/2`, `Omen.normalized/2`,
`Omen.lossy/2`, `Omen.rejected/2`). The omen carries:

- `code` — the `NYA-*` diagnostic code (see [diagnostics.md](diagnostics.md)).
- `severity` — one of the four levels.
- `schema_path` — the JSON path of the offending node.
- `rule` — a short machine-readable rule name (e.g.
  `additional_properties_false_dropped`).
- `source` / `target` — what the construct was, and what it became.
- `semantics_preserved` — `true` for `:exact`/`:normalized`, `false`
  otherwise.
- `explanation` — human-readable prose.
- `action` — optional suggestion for fixing the rejection.
- `tool` / `profile` — populated by the matrix command for cross-profile
  reports.

This structure flows unchanged through every report renderer (terminal,
JSON, JUnit, SARIF), so the same diagnostic data drives human-readable
output, CI test results, and GitHub Code Scanning.
