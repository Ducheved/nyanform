# Diagnostics

An `Omen` is Nyanform's structured diagnostic for a selected rewrite,
rejection, alias decision, or argument repair. The code catalog is broader than
the current set of runtime emitters.

Three cautions keep the output interpretable:

- Absence of omens does not mean byte-for-byte preservation. For example, the
  canonicalizer silently drops an unknown string format.
- `Pipeline.compile/2` currently returns `omens: []`; parser failures are
  `ValidationError` values and are usually collapsed to `NYA-SCHEMA-001` by
  callers.
- A catalog entry describes an available code and its default severity. It does
  not prove that a live code path currently emits it.

## Severity levels

| Severity | Order | `semantics_preserved` | Runtime policy meaning |
|---|---:|---:|---|
| `exact` | 0 | `true` | An emitted diagnostic says the examined construct was retained. Unchanged constructs do not necessarily emit one. |
| `normalized` | 1 | `true` | Nyanform classifies the rewrite as schema-semantics-preserving, such as const to a single-value enum or deterministic name repair. |
| `lossy` | 2 | `false` | Some constraint or information was dropped or relaxed. |
| `rejected` | 3 | `false` | The construct cannot be represented under the intended rule. |

`Omen.severity_order/1` defines the ordering and `Omen.worst/1` returns the
worst severity in a list. The ordinary severity gate works as follows: `strict`
rejects `lossy` and `rejected`; `compatible` rejects only `rejected`;
`permissive` admits every severity. Projector integrity checks for dangling
local pointers and required-name loss can still keep `accepted` false. The live
permissive catalog may publish a rejected schema only when its tool envelope is
structurally publishable.

## Omen fields

`Nyanform.Diagnostic.Omen` contains:

| Field | Meaning |
|---|---|
| `code` | Stable `NYA-*` identifier. |
| `severity` | `exact`, `normalized`, `lossy`, or `rejected`. |
| `schema_path` | String path segments for the affected schema node. |
| `rule` | Optional machine-oriented rule name. |
| `source` / `target` | Optional before/after descriptions. |
| `semantics_preserved` | Set by the severity constructor. |
| `explanation` | Human-readable reason. |
| `action` | Optional remediation text. |
| `tool` / `profile` | Optional context added by tool/profile reporting paths. |

The four constructors (`exact/2`, `normalized/2`, `lossy/2`, and `rejected/2`)
set `semantics_preserved` from severity.

## Code catalog

The severity below is the catalog default from `Diagnostic.Codes`. Some
projector branches deliberately emit the same code at another severity based on
policy. Examples include empty enums, unsupported `allOf`, and required closed
objects.

### Schema

| Code | Default | Catalog summary | Current emission status |
|---|---|---|---|
| `NYA-SCHEMA-001` | rejected | schema failed structural validation | `ToolGrimoire`, `inspect`, and `matrix` wrap compile failures with this general code. |
| `NYA-SCHEMA-002` | lossy | nullable type array normalized | Catalog only; no current emitter. |
| `NYA-SCHEMA-003` | lossy | `additionalProperties: false` dropped | Projector when a profile cannot preserve it. |
| `NYA-SCHEMA-004` | lossy | empty enum dropped | Projector; strict can emit it as rejected. |
| `NYA-SCHEMA-005` | rejected | mixed-type enum unsupported | Projector. |
| `NYA-SCHEMA-006` | rejected | tuple-style array unsupported | Projector; non-strict fallback may be lossy. |
| `NYA-SCHEMA-007` | rejected | union unsupported by profile | Projector. |
| `NYA-SCHEMA-008` | rejected | contradictory intersection | Projector while attempting `allOf` merge. |
| `NYA-SCHEMA-009` | rejected | array without items unsupported | Projector; exact when the profile accepts untyped arrays, otherwise rejected. `permissive` can still publish the rejected tool. |
| `NYA-SCHEMA-010` | rejected | schema depth exceeded | Catalog only. Parser depth errors remain atom-coded validation errors and are not mapped to this omen. |
| `NYA-SCHEMA-011` | rejected | reference cycle detected | Catalog only. The live pipeline marks recursive local refs instead of rejecting them. |
| `NYA-SCHEMA-012` | lossy | schema definitions dropped | Projector path for a profile with `reference_support: :none`; no current built-in profile selects that mode. |
| `NYA-SCHEMA-013` | rejected | required property is not declared | Projector when a profile must replace `required` with the complete `properties` key set and that rewrite would drop an undeclared required name. Canonical and passthrough preserve such names. |
| `NYA-SCHEMA-014` | rejected | local reference target is missing | Projector when a local JSON Pointer `$ref` does not resolve within the `max_schema_depth` source traversal. External URI, anchors, and targets below the traversal boundary are not classified by this check. |

### Profile

| Code | Default | Catalog summary | Current emission status |
|---|---|---|---|
| `NYA-PROFILE-001` | normalized | all properties marked required | Projector, notably `openai_strict`. |
| `NYA-PROFILE-002` | normalized | number type preserved without integer distinction | Emitter exists; no built-in currently disables integer/number distinction. |
| `NYA-PROFILE-003` | lossy | format keyword dropped | Projector when the format keyword or its concrete value is not accepted by the profile. |
| `NYA-PROFILE-004` | rejected | reference unsupported by profile | Projector. |
| `NYA-PROFILE-005` | lossy | pattern properties dropped | Projector. |
| `NYA-PROFILE-006` | normalized | const converted to single-value enum | Projector for `gemini` and `openai_strict`; strict policy accepts this normalized rewrite. |
| `NYA-PROFILE-007` | normalized | description truncated | Emitter exists; all built-ins currently use an unlimited description length. |
| `NYA-PROFILE-008` | rejected | root object required | Projector, currently used by `openai_strict`. |
| `NYA-PROFILE-009` | rejected | profile nesting limit exceeded | Projector, currently used for `openai_strict` object depth 10. |
| `NYA-PROFILE-010` | rejected | `allOf` unsupported by profile | Projector; strict rejects it, non-strict policies try a lossy merge. |
| `NYA-PROFILE-011` | lossy | closed object required by profile | Projector; schema-valued `additionalProperties` can instead be rejected or replaced lossily. |
| `NYA-PROFILE-012` | lossy | unsupported schema keyword dropped | Projector recursively removes selected scalar constraints and metadata outside the profile allowlist. Every normalized profile emits this code as rejected for retained unmodeled keywords such as `prefixItems`, `$id`, and `$schema`; vendor profiles also reject boolean schemas with it. |

`NYA-PROFILE-012` currently covers `title`, `default`, `examples`,
`minProperties`, `maxProperties`, `minItems`, `maxItems`, `uniqueItems`,
`pattern`, `minLength`, `maxLength`, `minimum`, `maximum`,
`exclusiveMinimum`, `exclusiveMaximum`, and `multipleOf` when present but not
accepted by the profile. Retained unmodeled annotations use the same code as
rejected, except internal `nya:combinator` metadata and configured vendor
extensions. `format`, `patternProperties`, combinators, and definitions have
their own codes.

### Alias

| Code | Default | Catalog summary | Current emission status |
|---|---|---|---|
| `NYA-ALIAS-001` | normalized | tool name sanitized | `ToolGrimoire`. |
| `NYA-ALIAS-002` | normalized | collision suffix added | `ToolGrimoire`. |
| `NYA-ALIAS-003` | rejected | ambiguous alias mapping | Catalog only; current collision handling creates deterministic unique suffixes. |

### Transport

| Code | Default | Catalog summary | Current emission status |
|---|---|---|---|
| `NYA-TRANSPORT-001` | rejected | message size exceeded | Catalog only as an `Omen`; transport returns ordinary errors. |
| `NYA-TRANSPORT-002` | rejected | malformed JSON-RPC frame | Catalog only as an `Omen`; parser returns an ordinary parse error. |
| `NYA-TRANSPORT-003` | rejected | request timeout | Catalog only as an `Omen`. |
| `NYA-TRANSPORT-004` | rejected | upstream process failure | Used as a CLI error label, not constructed as an `Omen`. |
| `NYA-TRANSPORT-005` | normalized | stdout protocol purity enforced | Catalog only. |
| `NYA-TRANSPORT-006` | rejected | session isolation violation | Used as a CLI HTTP-start error label, not constructed as an `Omen`. |

### Argument

| Code | Default | Catalog summary | Current emission status |
|---|---|---|---|
| `NYA-ARG-001` | normalized | JSON string repaired to object | `RewriteTalisman`. |
| `NYA-ARG-002` | normalized | JSON string repaired to array | `RewriteTalisman`. |
| `NYA-ARG-003` | rejected | argument repair rejected | Catalog only. |
| `NYA-ARG-004` | normalized | synthetic optional null removed | `RewriteTalisman` removes a `null` introduced only to represent an originally optional, non-nullable OpenAI property. |

The live `Session.Thread` forwards `repair_result.arguments` but currently
discards `repair_result.omens`. These codes are therefore observable to direct
callers of `RewriteTalisman`, not in the downstream `tools/call` response.

### Config

| Code | Default | Catalog summary | Current emission status |
|---|---|---|---|
| `NYA-CONFIG-001` | rejected | invalid configuration | Used as a CLI error label, not constructed as an `Omen`. |
| `NYA-CONFIG-002` | rejected | unknown profile | Catalog only; loaders return ordinary error tuples. |
| `NYA-CONFIG-003` | rejected | profile validation failed | Catalog only; loaders return ordinary error tuples. |

## Where diagnostics are assembled

- `Profile.Projector` creates schema/profile omens and determines projection
  acceptance.
- `ToolGrimoire` adds tool/profile context, alias omens, and the general
  `NYA-SCHEMA-001` compile-failure omen, then reapplies policy.
- `RewriteTalisman` returns argument-repair omens to its caller.
- CLI `inspect` and `matrix` build report inputs from compilation and
  projection. Textual CLI failures that include a `NYA-*` label are not
  automatically `Omen` structs.
- Report renderers can serialize the omens they receive; they cannot infer
  transformations for which no omen was emitted.

`Diagnostic.Codes` remains the metadata registry for `fetch/1`, `all/0`, and
`categories/0`. Treat it as a stable vocabulary, not as coverage evidence.
