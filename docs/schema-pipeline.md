# Schema pipeline

Nyanform's schema compiler turns an arbitrary upstream JSON Schema (the
`inputSchema` field of an MCP tool definition) into a canonical `Scroll`
struct, then optionally projects that struct into a client-specific
dialect. The pipeline is pure functional data transformation: no GenServer,
no side effects, no global state. Every stage is independently testable and
the whole thing is idempotent.

This document describes the eight stages, the canonical `Scroll` struct,
reference handling, idempotency, and the three transformation policies.

---

## The eight stages

The pipeline is orchestrated by `Nyanform.Schema.Pipeline.compile/2`. Stages
1-4, 7, and 8 produce a canonical `Scroll` and a digest; stages 5 and 6
(project and analyze) happen separately when a profile is applied.

### 1. Parse

`Nyanform.Schema.Parser.parse/4` walks the raw JSON term recursively and
builds a `Scroll` tree. For each node it chooses a `kind` based on the
JSON Schema keywords present:

- `$ref` → `:ref`
- `const` → `:const`
- `enum` → `:enum`
- `oneOf` or `anyOf` → `:union`
- `allOf` → `:intersection`
- `type` (single value) → that primitive kind
- `type` (array of types) → `:union` whose branches are the individual types
- Otherwise: inferred from `properties`/`additionalProperties` (`:object`),
  `items` (`:array`), or `:unknown`.

A JSON Schema of literal `true` parses to `:any`; `false` parses to
`:never`, following draft-07 / 2020-12 semantics.

The parser carries a `depth` counter and rejects schemas deeper than
`max_schema_depth` (default 64) with a `schema_depth_exceeded` error.

### 2. Structural validation

Validation happens inline during parsing. The parser returns
`Nyanform.Schema.ValidationError` for any of:

- `invalid_schema_node` — top-level node is not a map, `true`, or `false`.
- `invalid_enum` — `enum` is present but not a list.
- `missing_branches` / `invalid_branches` — `oneOf`/`anyOf`/`allOf` is
  missing or not a list.
- `invalid_property_map` — `properties` is not a map.
- `invalid_additional_properties` — `additionalProperties` is not a map,
  boolean, or absent.

Each error carries the JSON path of the offending node, so downstream
diagnostics can point precisely.

### 3. Canonicalization

`Nyanform.Schema.Canonicalizer.canonicalize/1` walks the parsed tree and
applies normalization rules so two equivalent source schemas produce the
same canonical form:

- `required` arrays are deduplicated (`Enum.uniq/1`).
- Empty property maps become `nil` (so `{}` and a missing `properties` are
  indistinguishable after canonicalization).
- String `format` values that are not in Nyanform's supported set are
  dropped. Supported formats: `date-time`, `date`, `time`, `duration`,
  `email`, `idn-email`, `hostname`, `idn-hostname`, `ipv4`, `ipv6`, `uri`,
  `uri-reference`, `iri`, `uuid`. Anything else is considered
  `:unsupported` and the `format` field is set to `nil`.
- Recursion is detected and marked (see stage 4).

### 4. Reference analysis

`Nyanform.Schema.Reference` resolves `$ref` against `$defs` and the legacy
`definitions` map. Reference targets are stored as path lists (e.g.
`["Foo", "bar"]` for `#/$defs/Foo/bar`); local vs. external references are
distinguished by whether the joined target string contains a `:`.

Cycle detection: `detect_cycles/2` walks the ref graph with a `seen`
MapSet; if it returns `true`, the pipeline calls `mark_recursive/5`, which
propagates a `recursive: true` flag down through properties, items,
branches, and additional-properties, bounded by `max_reference_depth`
(default 32). Recursive references are kept as `:ref` nodes in the
canonical form — they are not inlined, because inlining would either loop
forever or lose information.

If a reference chain exceeds `max_reference_depth` without cycling, the
resolver returns `reference_depth_exceeded`.

### 5. Profile projection

`Nyanform.Profile.Projector.project/3` takes a canonical `Scroll` and a
`Constellation` (compatibility profile) and produces a projected
JSON-Schema-shaped map suitable for that profile's client. This is where
profile-specific transformations happen:

- Objects emit `type: object` plus `properties`, `required`, and
  (conditionally) `additionalProperties: false`.
- Numbers emit `number` or `integer` depending on
  `integer_vs_number_distinguished`.
- Consts become `const` (if `supports_const`) or a single-value `enum`
  (otherwise).
- Unions become `oneOf`/`anyOf` if the profile supports them, collapse to
  a nullable single type when nullable, or are rejected.
- Intersections become `allOf` if supported, or are merged into a single
  object schema via property intersection (with conflict detection).
- `$ref` is preserved if the profile supports it (full or local-only), or
  rejected.
- Tuple arrays, untyped arrays, mixed-type enums, and empty enums are
  handled per the profile's `supported_array_forms` and
  `supported_enum_forms`.
- Descriptions are truncated to `max_description_length`.

See [compatibility-profiles.md](compatibility-profiles.md) for the per-
profile matrix.

### 6. Loss analysis

Every transformation during projection emits an `Omen` with a severity:

- `:exact` — no transformation; the construct passes through unchanged.
- `:normalized` — a reversible or semantics-preserving rewrite (e.g. all
  properties marked required, name sanitized, description truncated).
- `:lossy` — information was dropped (e.g. `additionalProperties: false`
  dropped, `format` keyword dropped, const demoted to enum).
- `:rejected` — the construct cannot be represented at all (e.g. union
  unsupported, mixed-type enum, tuple array unsupported, reference
  unsupported).

The four severities form a total order
(`exact < normalized < lossy < rejected`); `Omen.worst/1` returns the most
severe in a list. See [diagnostics.md](diagnostics.md).

### 7. Deterministic serialization

`Nyanform.Schema.Serializer.to_canonical_term/1` strips fields that are
not part of the schema's semantic content:

- `description`, `title`, `default`, `examples`, `raw`, `path` — all set to
  `nil` / `:unset` / `[]`.

It then builds a keyword list of the remaining fields, recursively
canonicalizing nested scrolls, sorting map keys alphabetically and list
entries by their canonical representation. The resulting Erlang term is
byte-stable: two scrolls that are semantically equal produce identical
terms.

### 8. Digest calculation

`Serializer.digest/1` runs
`:crypto.hash(:sha256, serialize(scroll)) |> Base.encode16(case: :lower)`.
The digest is the canonical fingerprint:

- `nyanform snapshot` records per-tool digests.
- `nyanform check` compares stored and live digests to detect breaking
  schema changes.
- The check command classifies changes as `breaking`,
  `potentially_breaking`, `metadata_only` (only the description changed),
  or `compatible` (tool added) based on digest equality.

---

## The canonical `Scroll` struct

`Nyanform.Schema.Scroll` is a plain Elixir struct with 34 fields. Each
field maps to a JSON Schema concept; absent values use `nil` (or `:unset`
for `default`/`const`, distinguishing "unset" from "explicitly null").

The 15 kinds:

| Kind | Source | Meaning |
|------|--------|---------|
| `:object` | `type: object` or presence of `properties`/`additionalProperties` | JSON object with properties, required, pattern properties, additional properties, min/max properties. |
| `:array` | `type: array` or presence of `items` | JSON array with homogeneous items, tuple items, additional items, min/max items, uniqueness. |
| `:string` | `type: string` | String with optional format, pattern, min/max length. |
| `:integer` | `type: integer` | Integer with numeric constraints. |
| `:number` | `type: number` | Number with numeric constraints. |
| `:boolean` | `type: boolean` | Boolean. |
| `:null` | `type: null` | JSON null. |
| `:enum` | `enum: [...]` | Closed set of allowed values. |
| `:const` | `const: <value>` | Single allowed value. |
| `:union` | `oneOf` / `anyOf` / array-of-types | Disjunction of branches. |
| `:intersection` | `allOf` | Conjunction of branches. |
| `:ref` | `$ref` | Reference to a definition. |
| `:any` | `true` / omitted type | Accepts anything. |
| `:never` | `false` | Accepts nothing. |
| `:unknown` | unrecognized type string | Schema Nyanform could not classify; raw is preserved. |

Helper predicates: `Scroll.object?/1`, `Scroll.ref?/1`,
`Scroll.primitive?/1`. Constructors: `Scroll.any/1`, `Scroll.never/1`.

---

## Reference resolution and cycle detection

`$ref` handling is split between the parser, the canonicalizer, and the
reference module:

1. **Parsing.** `Parser.parse_ref/4` extracts the `$ref` string, splits it
   into a path list (`split_ref/1` handles `#/foo/bar`,
   `#/`, bare URIs, and `uri#/fragment` forms), and stores the result as a
   `:ref` node with `ref_target` set to the path list.
2. **Definition extraction.** `Pipeline.resolve_definitions/3` pulls
   `$defs` (and the legacy `definitions`) from the raw map, parses each
   definition (bounded by `max_schema_depth`), and indexes them by path.
3. **Cycle detection.** `Reference.detect_cycles/2` walks the tree; if a
   ref target has been seen on the current path, it returns `true`.
4. **Marking.** `Pipeline.mark_recursive/5` propagates the `recursive`
   flag through the tree, bounded by `max_reference_depth`, so the
   serializer and projector can avoid infinite expansion.
5. **Resolution.** `Reference.resolve/2` is available for callers that
   want to inline non-recursive references; it returns the resolved
   scroll or marks recursion.

Recursive refs are preserved as `:ref` nodes in the canonical form. The
projector emits them as `$ref` strings for profiles that support
references; for profiles that do not, it emits a rejection omen.

---

## Idempotency guarantees

`Pipeline.compile_idempotent/1` runs the pipeline twice and asserts the
two digests are equal:

```
raw_schema
   │ compile
   ▼
first.scroll ─── first.digest
   │ compile   (on the struct, not the raw input)
   ▼
second.scroll ── second.digest
```

If `first.digest != second.digest`, the pipeline returns
`idempotency_violation`. This catches any non-idempotent transformation —
for example, a canonicalizer step that mutates the struct in a way that
survives a second pass.

The guarantee holds because:

- The canonicalizer is a pure tree rewrite with no mutable state.
- The serializer strips `path`, `raw`, and other non-semantic fields
  before computing the digest, so re-parsing a struct does not introduce
  path drift.
- Map keys are sorted, list entries are processed in order.

Property tests in `test/nyanform/schema/property_test.exs` exercise this
on generated schemas.

---

## The three transformation policies

The policy is a parameter to `Projector.project/3` and to
`ToolGrimoire.build/3`. It controls how aggressively the projector rewrites
and which severities cause a tool to be rejected.

| Policy | `:exact` | `:normalized` | `:lossy` | `:rejected` | Accepts |
|--------|----------|---------------|----------|-------------|---------|
| `:strict` (default) | accept | accept | **reject** | **reject** | only fully-compatible schemas |
| `:compatible` | accept | accept | accept | **reject** | anything that can be represented |
| `:permissive` | accept | accept | accept | accept | everything, even rejected constructs |

`policy_accepts?/2` in both `Projector` and `ToolGrimoire` implements this
table. The matrix command and the proxy both consult it when deciding
whether to mark a tool as accepted.

Strict is the safe default for production: it surfaces every lossy or
rejected construct as a failure, so silent information loss cannot slip
through. Compatible is appropriate when you know the client can tolerate
some normalization but want hard failures on genuinely unsupported
constructs. Permissive is for diagnostic and exploratory use: it lets you
see the projected schema even when it would normally be rejected.
