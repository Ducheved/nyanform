# Compatibility profiles

A Nyanform compatibility profile (`Constellation`) is an implementation
policy for reconstructing a canonical `Scroll`. Except for the normative facts
linked below, profile values are Nyanform behavior, not a vendor guarantee.

This document separates three evidence layers: vendor API rules, documented
Gemini CLI behavior, and Nyanform's own compatibility hypotheses.

## Evidence boundary

### 1. Official protocol and vendor API rules

- The MCP tools specification defines `inputSchema` as a JSON Schema object,
  defaults its dialect to JSON Schema 2020-12 when `$schema` is absent, and
  recommends portable tool-name characters and a 1-128 length range. See the
  official [MCP tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).
- OpenAI strict function calling requires `additionalProperties: false` on
  every object and every property to be listed in `required`; optional values
  are represented by including `null` in the type. See
  [OpenAI function calling: strict mode](https://developers.openai.com/api/docs/guides/function-calling#strict-mode).
- OpenAI Structured Outputs requires an object root rather than a root
  `anyOf`, allows valid `anyOf` below the root, supports definitions and
  recursive schemas, and does not support `allOf`. Its documentation also
  lists nesting and size budgets. See the official
  [Structured Outputs guide](https://developers.openai.com/api/docs/guides/structured-outputs#supported-schemas).
- Anthropic documents a tool `input_schema` as JSON Schema and the name pattern
  `^[a-zA-Z0-9_-]{1,64}$`, but that page does not publish the complete subset
  encoded by Nyanform's `claude` profile. See
  [Anthropic tool definitions](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools).
- Google's API documentation publishes its own function-declaration schema
  fields and limits. Those API rules are not automatically a contract for the
  Gemini CLI MCP adapter. See the official
  [Vertex AI function-calling guide](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/multimodal/function-calling)
  and [Gemini API function-calling guide](https://ai.google.dev/gemini-api/docs/function-calling).
- VS Code documents MCP server integration but does not publish a complete
  client-side JSON Schema subset matching Nyanform's `vscode` profile. See
  [VS Code MCP servers](https://code.visualstudio.com/docs/agent-customization/mcp-servers).

### 2. Documented Gemini CLI behavior

The official
[Gemini CLI MCP documentation](https://geminicli.com/docs/tools/mcp-server/)
states that its schema sanitizer removes `$schema` and
`additionalProperties` before sending function declarations to the Gemini API.
It also documents tool-name sanitization and a 63-character maximum.

Nyanform's `gemini` profile currently preserves
`additionalProperties: false`. That means Nyanform acceptance is not evidence
that closed-object semantics survive the later Gemini CLI sanitizer.

### 3. Nyanform hypotheses

The `claude`, `gemini`, and `vscode` capability matrices below include choices
that are not fully specified by the linked vendor pages. They are current
Nyanform assumptions and should be validated against the exact client/version
used in deployment. `openai_strict` implements a useful subset of the official
rules but also has explicit enforcement gaps described below.

## Built-in behavior

`Builtins.all/0` returns six profiles. All structs set
`nullable_representation: :type_array`; the normalized profiles therefore emit
a nullable primitive as, for example, `type: ["string", "null"]`. The
`passthrough` special case bypasses that projection and returns the source form.
An explicit source `anyOf` remains a combinator when the normalized target
supports `anyOf`; nullable handling does not silently replace it with a
non-equivalent primitive.

Legend: H = homogeneous, T = tuple, N = no `items`, M = mixed, E = empty.

| Profile | Schema output | Combinators | References | Const | `additionalProperties: false` | Arrays | Enums | Profile depth | Tool names |
|---|---|---|---|---|---|---|---|---|---|
| `canonical` | normalized reconstruction; raw fallback for `:unknown` | `oneOf`, `anyOf`, `allOf` | full | preserved | preserved | H/T/N | H/M/E | unlimited | `^[a-zA-Z0-9_.-]{1,128}$` |
| `claude` | normalized reconstruction; raw fallback for `:unknown` | `oneOf`, `anyOf`, `allOf` | local only | preserved | preserved | H/T | H/M | unlimited | `^[a-zA-Z0-9_-]{1,64}$` |
| `gemini` | normalized reconstruction; raw fallback for `:unknown` | `oneOf`, `anyOf` | local only | single-value enum | preserved by Nyanform | H | H | unlimited | `^[a-zA-Z0-9_.:-]{1,63}$` |
| `openai_strict` | normalized reconstruction | `anyOf` | local only | single-value enum | required on every object | H | H | object depth 10; schema depth unlimited | `^[a-zA-Z0-9_-]{1,64}$` |
| `vscode` | normalized reconstruction; raw fallback for `:unknown` | `oneOf`, `anyOf`, `allOf` | local only | preserved | preserved | H/T | H/M | unlimited | `^[a-zA-Z0-9_.-]{1,128}$` |
| `passthrough` | retained raw root schema | projection bypassed | projection bypassed | projection bypassed | projection bypassed | projection bypassed | projection bypassed | projection bypassed | aliases still use `^[a-zA-Z0-9_.-]{1,128}$` |

All built-ins currently set `max_description_length: :unlimited`. There are no
built-in Claude, Gemini, or VS Code schema-depth limits. These omissions are
intentional: Nyanform does not claim undocumented limits for those clients.

`local only` means `Reference.uri == ""`. It includes local JSON Pointers such
as `#/$defs/Foo`; it does not include a non-empty relative or absolute URI.

## Canonical versus passthrough

The distinction is narrower than their names may suggest:

- `canonical` reconstructs modeled schemas from normalized `Scroll` fields. It
  can sort `required`, normalize child maps, and omit source syntax that the
  parser does not model. An `:unknown` `Scroll` falls back to its retained raw
  schema. Boolean schemas remain `true` or `false`. Unmodeled schema keywords
  such as `prefixItems`, plus `$id` and `$schema`, emit rejected
  `NYA-PROFILE-012` instead of being removed silently.
- `passthrough` is a `Projector` special case returning the retained raw schema,
  using `%{}` only when `scroll.raw` is `nil`. It still rejects dangling local
  JSON Pointer targets found within the `max_schema_depth` traversal, but
  preserves valid undeclared names in `required`.

Even under `passthrough`, `ToolGrimoire` first compiles the schema, sanitizes
tool names, resolves collisions, and reconstructs the tool object. The live
response preserves `outputSchema`, `annotations`, and `_meta` when present, but
does not preserve arbitrary other tool-level fields. JSON-RPC is also decoded
and encoded again. `passthrough` therefore means raw input-schema projection,
not byte-for-byte MCP passthrough.

## `openai_strict` in current code

The current allowlist is:

```text
type properties required additionalProperties items description enum
minimum maximum exclusiveMinimum exclusiveMaximum multipleOf
minItems maxItems pattern format anyOf $ref $defs
```

The profile and projector enforce these behaviors:

- the projected root must be an object (`NYA-PROFILE-008` otherwise);
- every projected object receives all of its property names in `required`;
  properties that were optional gain `null`, and live argument repair removes
  that synthetic `null` before calling an upstream schema that did not accept
  it. If the property also has an `enum`, `null` is added to the enum as well;
- every projected object receives `additionalProperties: false`;
- changing omitted or `true` `additionalProperties` to `false` is lossy
  (`NYA-PROFILE-011`), so `strict` rejects that tool while `compatible` accepts
  the narrowed projection;
- schema-valued `additionalProperties` is rejected under `strict`, or replaced
  by `false` with a lossy `NYA-PROFILE-011` under non-strict policy;
- nested `anyOf`, local `$ref`, and `$defs` are preserved;
- legacy `definitions` containers are emitted as `$defs`, including at nested
  schema nodes, and matching local JSON Pointer references are rewritten;
- a root `anyOf` is rejected by the root-object rule;
- `allOf` is rejected under `strict`; `compatible`/`permissive` attempt a lossy
  object merge with `NYA-PROFILE-010`, and contradictory branches emit
  `NYA-SCHEMA-008`;
- `const` becomes an equivalent single-value `enum` with normalized
  `NYA-PROFILE-006`, which remains accepted under `strict`;
- `format` is limited to `date-time`, `time`, `date`, `duration`, `email`,
  `hostname`, `ipv4`, `ipv6`, and `uuid`; other retained formats are omitted
  with lossy `NYA-PROFILE-003`;
- object nesting beyond 10 emits rejected `NYA-PROFILE-009`;
- unsupported scalar constraints and metadata represented by `Scroll` are
  omitted with lossy `NYA-PROFILE-012`. This includes `minLength` and
  `maxLength`, which are not in the current OpenAI allowlist. `strict` rejects
  a tool with such a lossy diagnostic;
- boolean schemas, untyped schemas, and unmodeled keywords such as `not`,
  `if`/`then`/`else`, and `dependentSchemas` are rejected with
  `NYA-PROFILE-012`. `strict` and `compatible` omit such tools; `permissive`
  deliberately publishes rejected projections.
- arrays without `items` are rejected with `NYA-SCHEMA-009` under both
  `strict` and `compatible`; `permissive` can still publish them.

An explicitly nullable optional property keeps its `null` value. Only the
synthetic `null` introduced for a non-nullable optional source property is
removed before the upstream call.

The implementation checks only the structural rules above and
`max_object_depth: 10`. It does **not** enforce OpenAI's other documented size
budgets, including total property count, total schema-string length, or enum
count/string budgets. In particular, the official 5,000-property and 120,000
total-string-character limits are not implemented. Passing Nyanform projection
is therefore not a complete OpenAI server-side validation.

## Gemini profile in current code

The `gemini` profile supports `oneOf` and `anyOf`, local references,
homogeneous arrays and enums, and these accepted keywords:

```text
type properties required additionalProperties items description enum format
minimum maximum minLength maxLength oneOf anyOf $ref $defs
```

It converts `const` to a single-value enum with normalized
`NYA-PROFILE-006`. It preserves `additionalProperties: false` without
`NYA-SCHEMA-003`, and it has no Gemini-profile-specific schema-depth cap. The
global parser limit still applies.

These are Nyanform projection decisions. As noted above, the documented Gemini
CLI sanitizer later removes `additionalProperties`; users must not infer
end-to-end closed-object enforcement from a successful Nyanform projection.

## Other profile boundaries

- `claude` and `vscode` preserve `const`, local references,
  `additionalProperties: false`, tuple arrays, mixed enums, and all three
  combinators according to Nyanform's current hypotheses.
- Canonical preserves JSON Schema boolean values. Claude, Gemini,
  `openai_strict`, and VS Code emit rejected `NYA-PROFILE-012` for boolean
  schemas instead of silently replacing them with `{}` or `not`.
- None of the vendor profiles accepts modeled `patternProperties`; the
  projector emits lossy `NYA-PROFILE-005` when it drops them.
- Every normalized profile emits rejected `NYA-PROFILE-012` for retained
  unmodeled schema keywords, including root or nested `$id`, `$schema`, and
  applicators such as `prefixItems`. Internal `nya:combinator` metadata and
  configured vendor-extension prefixes are excluded. Use `passthrough` when
  those keywords must reach the client unchanged; under `strict` or
  `compatible`, the affected normalized tool is isolated.
- Unsupported `format` uses `NYA-PROFILE-003`. Other selected unsupported
  scalar constraints and metadata use `NYA-PROFILE-012`. Unknown string formats
  may already have been silently removed during canonicalization, before a
  profile is selected.
- `canonical` and `passthrough` are Nyanform modes, not vendor profiles.

The exact internal keyword sets are defined in
`Nyanform.Profile.Builtins`. Keyword membership is only one part of projection;
combinators, references, array/enum forms, object closure, root shape, and depth
have separate controls.

## Policies and live proxy behavior

| Policy | Accepted severities |
|---|---|
| `strict` | exact and normalized |
| `compatible` | exact, normalized, and lossy |
| `permissive` | every severity, including rejected |

The projector keeps its `accepted` field false for dangling local JSON Pointer
targets found within the bounded traversal under every policy. It does the same
for undeclared required names only when the selected profile replaces
`required` with the complete `properties` key set. `ToolGrimoire` can still
publish rejected entries when the live policy is `permissive` and the tool
envelope is structurally publishable.

`Projector` calculates acceptance, then `ToolGrimoire` combines projection,
compile, and alias omens and applies the policy again. The live proxy omits
unaccepted tools from `tools/list` unless policy is `permissive` and the tool
envelope is structurally publishable. Rejected tools receive no callable alias
under `strict` or `compatible`, so a direct `tools/call` cannot bypass the
catalog decision. Under `permissive`, publishable rejected schemas can be
exposed, but malformed catalog containers and entries without a string name or
`inputSchema` remain hidden.

## Configuration, programmatic overrides, and `auto`

`nyanform.json` and the CLI select a profile name and policy. They do not expose
profile-field overrides.

`Profile.Loader.load/2` does accept a map of overrides as a programmatic API,
including structural flags and depth/name/description limits, but no current
runtime configuration path calls it with overrides. Describing those overrides
as configuration-file support would be incorrect.

The `auto` profile is a client-name heuristic, not capability negotiation. It
matches names containing `claude` or `cline`, `openai`, `gemini`, `vscode`, or
`vs code`; unknown names fall back to `canonical`.
