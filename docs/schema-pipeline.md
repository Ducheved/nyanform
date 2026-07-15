# Schema pipeline

Nyanform parses a tool's raw `inputSchema` into a canonical `Scroll`, marks
recursive local references, and computes a deterministic digest. Projection to
a client profile is a separate operation.

The distinction is important: `Pipeline.compile/2` does not run an eight-stage
parse-to-profile workflow, and a successful compile does not prove that a
particular profile accepts the schema.

## What `Pipeline.compile/2` actually runs

The returned `stages` list contains exactly these four entries:

| Recorded stage | Implementation |
|---|---|
| `:parse` | `Parser.parse/4`; structural validation is inline. |
| `:canonicalize` | `Canonicalizer.canonicalize/1`. |
| `:references` | Pipeline-local recursive-reference marking. |
| `:digest` | `Serializer.digest/1`, which performs serialization internally. |

The result contains the canonical `scroll`, its `digest`, an empty `omens`
list, and timing entries. `:validate`, `:project`, `:analyze`, and `:serialize`
exist in the stage type but are not emitted by the current orchestration.

Profile projection happens later through `Projector.project/3`, usually from
`ToolGrimoire`, `inspect`, or `matrix`.

## Parse and structural validation

The parser accepts a JSON object, literal `true`, literal `false`, or an already
constructed `Scroll`:

- `true` becomes `:any`; `false` becomes `:never`.
- `oneOf` wins over `anyOf`, which wins over `allOf` when more than one
  combinator is present. A combinator wins over `$ref` and ordinary type/value
  parsing.
- `$ref` wins over ordinary type/value parsing when no combinator is selected.
- A valid `type` decides the node kind. `const` and `enum` can still be
  retained as constraints on that typed node.
- With no type, `const` selects `:const`, then `enum` selects
  `:enum`.
- With no type, `properties` or `additionalProperties` infer `:object`, `items`
  infers `:array`, and an otherwise untyped schema becomes `:unknown`.
- A multi-value `type` array becomes a union and a single-value array becomes
  that type. Unknown type names, non-string members, empty arrays, and duplicate
  members are structural errors.
- Boolean child schemas are retained. In particular, `items: false` becomes a
  `:never` child and has a different digest from an array without `items`.

The 15 possible kinds are `:object`, `:array`, `:string`, `:integer`,
`:number`, `:boolean`, `:null`, `:enum`, `:const`, `:union`, `:intersection`,
`:ref`, `:any`, `:never`, and `:unknown`.

Structural errors are `ValidationError` values with atom codes and paths. The
parser checks such cases as an invalid root node or type, explicit `null` or an
invalid shape for modeled keywords, empty or malformed combinator branches,
invalid schema children, malformed `required`, invalid numeric/string
constraint values, and the parser depth limit. Shape validation covers modeled
siblings even when another type, `$ref`, or combinator wins dispatch. This is
still not a complete JSON Schema metaschema validator; unmodeled keywords are
handled later by profile projection.

Every parsed schema node attaches `$defs`, or legacy `definitions` when `$defs`
is absent, to its own `scroll.definitions`. Each node retains its source map in
`raw`.

## Canonicalization

`Canonicalizer.canonicalize/1` recursively normalizes schema children and
definitions. In current code it:

- deduplicates and sorts each `required` list;
- replaces empty property, pattern-property, and definition maps with `nil`;
- canonicalizes properties, pattern properties, array items, branches,
  additional-property schemas, and definitions;
- removes unrecognized string `format` values.

Supported string formats are `date-time`, `date`, `time`, `duration`, `email`,
`idn-email`, `hostname`, `idn-hostname`, `ipv4`, `ipv6`, `uri`,
`uri-reference`, `iri`, and `uuid`.

The unsupported-format removal is currently silent: `Pipeline.compile/2`
returns no omen for it. A later `NYA-PROFILE-003` applies when a retained
canonical format is removed because the selected profile rejects the `format`
keyword or that concrete format value.

Canonicalization does not sort branch order, tuple-item order, or enum values.
Those lists retain their semantic source order.

## Reference handling

References are represented by `%Reference{uri, fragment}`. A reference is
local exactly when `uri == ""`; this is not inferred from punctuation in the
original string.

The pipeline's `:references` operation is narrower than the public
`Reference` module:

- It follows only local JSON Pointer references whose first path segment is
  `$defs` or `definitions` and whose definition name exists at the root.
- It follows them only to decide whether the original `:ref` node should have
  `recursive: true`.
- It does not inline targets, reject unresolved references, or reject external
  references.
- Reaching `max_reference_depth` marks the reference recursive instead of
  returning an error.

`Reference.resolve/2` and `Reference.detect_cycles/2` are public helpers with
their own behavior, but `Pipeline.compile/2` does not call them. In particular,
the catalog entry `NYA-SCHEMA-011` is not a statement that the live pipeline
rejects cycles; the pipeline preserves and marks recursive local references.

Profile projection later decides whether a preserved reference is supported:
`:full` accepts any URI, `:local_only` accepts only `uri == ""`, and `:none`
rejects references. Projection also rejects local JSON Pointer references whose
targets do not exist in the source document within the `max_schema_depth`
traversal boundary. Recursive references remain valid; external URI and anchor
references are outside that target-existence check, and deeper targets are left
unclassified when the bounded walker stops.

## Deterministic serialization and digest

`Serializer.to_canonical_term/1` recursively removes descriptive/source fields
from every `Scroll` node:

- `description`
- `title`
- `default`
- `examples`
- `raw`
- `path`

It preserves annotations, node kinds, structural children, constraints,
references, and recursion markers. Struct fields and named child maps are
sorted by key. Semantic lists such as union branches, tuple items, and enum
values are kept in order; `required` has already been sorted by the
canonicalizer.

`Serializer.serialize/1` performs:

```text
canonical term -> :erlang.term_to_binary -> lowercase hexadecimal string
```

`Serializer.digest/1` hashes that hexadecimal string with SHA-256 and returns a
64-character lowercase hexadecimal digest.

Consequences of the current digest boundary:

- nested descriptive metadata does not affect the digest;
- ordering of `required`, properties, and definitions does not affect it;
- branch, tuple-item, and enum ordering can affect it;
- annotations and semantic constraints affect it;
- digest equality is a deterministic equality check for Nyanform's canonical
  representation, not a proof of general JSON Schema semantic equivalence.

`Pipeline.compile_idempotent/1` compiles the raw value, compiles the resulting
`Scroll`, and compares the two digests. A mismatch returns
`idempotency_violation`.

## Projection is separate

For ordinary profiles, `Projector.project/3` recursively reconstructs a JSON
Schema-shaped map from the canonical `Scroll`, collects profile omens, and
calculates acceptance for the selected policy.

Definitions are projected at the schema node that owns them. They are emitted
as `$defs`; local JSON Pointer references that used a legacy `definitions`
segment are rewritten against the final projected schema so nested pointers do
not dangle.

Two profiles define the output boundary explicitly:

- `canonical` is a normalized reconstruction for modeled schemas. An
  `:unknown` `Scroll` uses its retained raw schema as a fallback, and boolean
  schemas remain boolean values. Retained unmodeled keywords such as
  `prefixItems`, `$id`, and `$schema` emit rejected `NYA-PROFILE-012` rather
  than disappearing silently.
- `passthrough` is a projector special case that returns the retained raw
  schema, using `%{}` only when `scroll.raw` is `nil`. It still reports dangling
  local JSON Pointer references found within the bounded traversal. It does not
  bypass tool compilation, aliases, tool-definition reconstruction, or
  transport re-encoding.

The projector emits diagnostics for selected rewrites such as unsupported
keywords, constraints, combinators, references, array/enum forms, required
closed objects, and profile depth. Every normalized profile rejects retained
unmodeled annotations except internal combinator metadata and configured vendor
extensions. It does not retroactively report canonicalizer changes such as an
unknown format already removed before projection.

## Policies and live enforcement

| Policy | `exact` | `normalized` | `lossy` | `rejected` |
|---|---:|---:|---:|---:|
| `strict` | accept | accept | reject | reject |
| `compatible` | accept | accept | accept | reject |
| `permissive` | accept | accept | accept | accept |

Dangling local JSON Pointer targets keep the projection unaccepted under every
policy. An undeclared required name does the same only for profiles that replace
`required` with the complete `properties` key set; canonical and passthrough
preserve that valid JSON Schema constraint. The live `permissive` catalog can
still publish rejected entries as described in the compatibility profile
documentation.

`Projector` calculates acceptance from its omens. `ToolGrimoire` then combines
projection omens with compilation and alias omens and applies the policy again.
The proxy exposes only accepted tools unless policy is `permissive`, and only
structurally publishable exposed/permissive tools receive callable aliases.
Malformed tool envelopes and non-list catalog values are never made callable.

## Snapshot and check semantics

`nyanform snapshot` stores per-tool schema digests. `nyanform check` currently
classifies changes as follows:

| Observed change | Classification |
|---|---|
| live tool added | `compatible` |
| stored tool removed | `breaking` |
| the input/output comparisons match, but the top-level tool description changed and the input schemas compare equal without their root description | `metadata_only` |
| both input digests are available and either the input or output comparison differs | `breaking` |
| at least one input digest is unavailable and the input/output comparisons do not both match | `potentially_breaking` |

Because the digest recursively strips descriptive metadata, a nested
description-only edit can compare as no change rather than `metadata_only`.
The `metadata_only` label is specifically reached through the top-level tool
description check; it is not a general schema-diff engine.
