# Diagnostics

Nyanform records every transformation it applies to a schema as a
structured diagnostic called an **omen**. Omens are the primary output of
`nyanform inspect` and `nyanform matrix`, and they flow through every
report renderer (terminal, JSON, JUnit, SARIF).

This document lists every diagnostic code, the four severity levels, and
the structure of an omen.

---

## Severity levels

Every omen has one of four severities, ordered from least to most severe:

| Severity | Order | Semantics preserved | Meaning |
|----------|-------|---------------------|---------|
| `:exact` | 0 | yes | The construct passed through unchanged. No information was added or lost. |
| `:normalized` | 1 | yes | A reversible or semantics-preserving rewrite was applied (e.g. all properties marked required, name sanitized, description truncated, JSON-string argument repaired). The schema's meaning is unchanged. |
| `:lossy` | 2 | **no** | Information was dropped (e.g. `additionalProperties: false` removed, `format` keyword dropped, `const` demoted to single-value `enum`). The schema is more permissive than the original. |
| `:rejected` | 3 | **no** | The construct cannot be represented in the target profile at all (e.g. union unsupported, mixed-type enum, tuple array unsupported, reference unsupported). |

`Nyanform.Diagnostic.Omen.severity_order/1` returns the numeric ordering;
`Omen.worst/1` returns the most severe severity in a list. The policy
(`strict` / `compatible` / `permissive`) decides which severities cause a
tool to be marked as not accepted.

---

## Omen structure

`Nyanform.Diagnostic.Omen` is a struct with these fields:

| Field | Type | Description |
|-------|------|-------------|
| `code` | `String.t()` | The `NYA-*` diagnostic code. |
| `severity` | `:exact` \| `:normalized` \| `:lossy` \| `:rejected` | Severity level. |
| `schema_path` | `[String.t()]` | JSON path of the offending node (e.g. `["properties", "user", "items"]`). |
| `rule` | `String.t()` \| `nil` | Short machine-readable rule name (e.g. `mixed_enum_unsupported`). |
| `source` | `String.t()` \| `nil` | What the construct was before transformation. |
| `target` | `String.t()` \| `nil` | What the construct became. `nil` for rejections (nothing was produced). |
| `semantics_preserved` | `boolean()` | `true` for `:exact` and `:normalized`; `false` otherwise. |
| `explanation` | `String.t()` | Human-readable prose. |
| `action` | `String.t()` \| `nil` | Optional suggested fix. Populated for rejections. |
| `tool` | `String.t()` \| `nil` | Tool name. Populated by the matrix command. |
| `profile` | `String.t()` \| `nil` | Profile name. Populated by the matrix command. |

Omens are constructed via the four severity constructors
(`Omen.exact/2`, `Omen.normalized/2`, `Omen.lossy/2`, `Omen.rejected/2`),
which set `semantics_preserved` automatically.

---

## Diagnostic codes by category

All codes are catalogued in `Nyanform.Diagnostic.Codes`. Use
`Codes.fetch/1` to look up a code's category, default severity, and
summary; `Codes.all/0` returns the full map; `Codes.categories/0` returns
the distinct categories.

### Schema (NYA-SCHEMA-001 — NYA-SCHEMA-011)

Emitted during parsing, canonicalization, and projection when the schema
itself contains a construct that the pipeline cannot faithfully handle.

| Code | Severity | Summary |
|------|----------|---------|
| `NYA-SCHEMA-001` | rejected | schema failed structural validation |
| `NYA-SCHEMA-002` | lossy | nullable type array normalized |
| `NYA-SCHEMA-003` | lossy | additionalProperties: false dropped |
| `NYA-SCHEMA-004` | lossy | empty enum dropped |
| `NYA-SCHEMA-005` | rejected | mixed-type enum unsupported |
| `NYA-SCHEMA-006` | rejected | tuple-style array unsupported |
| `NYA-SCHEMA-007` | rejected | union unsupported by profile |
| `NYA-SCHEMA-008` | rejected | contradictory intersection |
| `NYA-SCHEMA-009` | rejected | array without items unsupported |
| `NYA-SCHEMA-010` | rejected | schema depth exceeded |
| `NYA-SCHEMA-011` | rejected | reference cycle detected |

### Profile (NYA-PROFILE-001 — NYA-PROFILE-007)

Emitted during projection when a profile-specific transformation is
applied.

| Code | Severity | Summary |
|------|----------|---------|
| `NYA-PROFILE-001` | normalized | all properties marked required |
| `NYA-PROFILE-002` | normalized | number type preserved without integer distinction |
| `NYA-PROFILE-003` | lossy | format keyword dropped |
| `NYA-PROFILE-004` | rejected | reference unsupported by profile |
| `NYA-PROFILE-005` | lossy | pattern properties dropped |
| `NYA-PROFILE-006` | rejected | const unsupported by profile |
| `NYA-PROFILE-007` | normalized | description truncated |

### Alias (NYA-ALIAS-001 — NYA-ALIAS-003)

Emitted by `Nyanform.ToolGrimoire` when a tool name must be rewritten to
satisfy a profile's `tool_name_pattern`.

| Code | Severity | Summary |
|------|----------|---------|
| `NYA-ALIAS-001` | normalized | tool name sanitized |
| `NYA-ALIAS-002` | normalized | collision suffix added |
| `NYA-ALIAS-003` | rejected | ambiguous alias mapping |

### Transport (NYA-TRANSPORT-001 — NYA-TRANSPORT-006)

Emitted by the transport layer when a JSON-RPC frame or upstream
connection fails.

| Code | Severity | Summary |
|------|----------|---------|
| `NYA-TRANSPORT-001` | rejected | message size exceeded |
| `NYA-TRANSPORT-002` | rejected | malformed JSON-RPC frame |
| `NYA-TRANSPORT-003` | rejected | request timeout |
| `NYA-TRANSPORT-004` | rejected | upstream process failure |
| `NYA-TRANSPORT-005` | normalized | stdout protocol purity enforced |
| `NYA-TRANSPORT-006` | rejected | session isolation violation |

### Argument (NYA-ARG-001 — NYA-ARG-003)

Emitted by `Nyanform.RewriteTalisman` when repairing client arguments
that were serialized incorrectly (e.g. a JSON object sent as a string).

| Code | Severity | Summary |
|------|----------|---------|
| `NYA-ARG-001` | normalized | JSON string argument repaired to object |
| `NYA-ARG-002` | normalized | JSON string argument repaired to array |
| `NYA-ARG-003` | rejected | argument repair rejected |

### Config (NYA-CONFIG-001 — NYA-CONFIG-003)

Emitted by `Nyanform.Config.Loader` and the CLI when configuration is
invalid.

| Code | Severity | Summary |
|------|----------|---------|
| `NYA-CONFIG-001` | rejected | invalid configuration |
| `NYA-CONFIG-002` | rejected | unknown profile |
| `NYA-CONFIG-003` | rejected | profile validation failed |

---

## How codes are emitted

Codes are produced at three points:

1. **Parsing/canonicalization** — `Nyanform.Schema.Parser` and
   `Canonicalizer` return `ValidationError` structs whose `code` field is
   an atom (e.g. `:schema_depth_exceeded`). The CLI translates these to
   the corresponding `NYA-SCHEMA-*` string code when constructing an
   omen.
2. **Projection** — `Nyanform.Profile.Projector` constructs omens directly
   with the `NYA-SCHEMA-*` / `NYA-PROFILE-*` string codes.
3. **Tool catalog** — `Nyanform.ToolGrimoire` constructs
   `NYA-ALIAS-*` and `NYA-SCHEMA-001` omens when sanitizing names or
   failing to compile a schema.

The `Codes` module is the single source of truth for code metadata. The
SARIF renderer reads it to populate the `rules` array, and the terminal
renderer uses severities to decide display formatting.
