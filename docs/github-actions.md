# GitHub Actions

Nyanform ships a CI workflow at `.github/workflows/ci.yml` that runs the
full quality gate on every push and pull request. This document describes
what the workflow does, how to consume its SARIF output in GitHub Code
Scanning, and how to use `nyanform matrix` for snapshot-based regression
detection in your own pipelines.

---

## What the CI workflow runs

The workflow runs on `ubuntu-latest` against Elixir 1.20 and OTP 29, on
both `push` (to `main`) and `pull_request` events. It performs these jobs
in order:

| Step | Command | Purpose |
|------|---------|---------|
| 1. Checkout | `actions/checkout@v4` | Fetch the source. |
| 2. Setup BEAM | `erlef/setup-beam@v1` | Install Elixir 1.20 and OTP 29. |
| 3. Dependencies | `mix deps.get` | Fetch locked dependencies. |
| 4. Compile | `mix compile --warnings-as-errors` | Type-strict compile; any warning fails the build. |
| 5. Format check | `mix format --check-formatted` | Reject unformatted code. |
| 6. No-comments | `mix nyanform.no_comments` | Custom gate: forbids `#` comments and `@moduledoc`/`@doc`/`@typedoc` attributes in `lib/`, `config/`, `test/`, `priv/`, `rel/`, and forbids comments in shell scripts, Dockerfiles, and YAML. |
| 7. Credo strict | `mix credo --strict` | Static analysis with all checks enabled (see [quality-exceptions.md](quality-exceptions.md) for exceptions). |
| 8. Tests | `mix test` | Unit and integration tests (property tests excluded by default). |
| 9. Property tests | `mix test --include property:true` | StreamData property tests. |
| 10. Dialyzer | `mix dialyzer` | Type analysis; PLT cached under `priv/plts/`. |
| 11. Escript build | `mix escript.build` | Build and smoke-test the standalone `./nyanform` executable. |
| 12. Docker build | `docker build -t nyanform:ci .` | Build the production image. |
| 13. E2E smoke test | run the escript against a fixture server and assert `inspect` exits 0 | End-to-end validation. |
| 14. Artifact package | archive `nyanform` as `nyanform-linux.tar.gz` | Preserve the executable mode in the uploaded artifact. |

The local `mix quality` alias runs steps 4-8. The `mix ci` alias runs
steps 4-10 in one command:

```sh
mix ci
```

The Docker build and e2e smoke test run only in CI, not in the alias.

---

## Using `nyanform matrix` in CI

The `matrix` command compiles an MCP server against every built-in profile
and emits a report. In CI, use SARIF output and upload it to GitHub Code
Scanning:

```yaml
- name: Run compatibility matrix
  run: |
    ./nyanform matrix \
      --stdio-command node \
      --stdio-arg server.js \
      --format sarif \
      --output nyanform.sarif

- name: Upload SARIF to GitHub Code Scanning
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: nyanform.sarif
```

The SARIF renderer (`Nyanform.Report.Sarif`) emits a SARIF 2.1.0 document
with:

- One `run` whose `tool.driver` is Nyanform (version, information URI).
- A `rules` array populated from `Nyanform.Diagnostic.Codes`, so each
  `NYA-*` code appears as a rule with its default severity mapped to a
  SARIF level (`error` for rejected, `warning` for lossy, `note` for
  normalized, `none` for exact).
- A `results` array with one entry per omen, carrying the rule ID, level,
  message, and a location whose snippet is the JSON path.

GitHub will render these as code-scanning alerts on the repository's
Security tab.

### Exit codes

`nyanform matrix` exits non-zero when the report contains rejected or
lossy omens, controlled by flags:

| Flag | Default | Effect |
|------|---------|--------|
| `--fail-on-rejected` | `true` | Exit 1 if any tool is rejected under any profile. |
| `--fail-on-lossy` | `false` | Exit 1 if any tool has a lossy projection. |

For CI gates that should block on any information loss, pass both:

```sh
nyanform matrix --stdio-command node --stdio-arg server.js \
  --fail-on-rejected --fail-on-lossy
```

---

## Snapshot-based regression detection

`nyanform snapshot` and `nyanform check` together implement deterministic
regression detection for upstream MCP servers.

### Producing a snapshot

```sh
nyanform snapshot \
  --stdio-command node \
  --stdio-arg server.js \
  --output _snapshots/server.json
```

The snapshot file records, for each tool:

- `name`, `description`, `input_schema`, `output_schema`
- `digest` — the SHA-256 of the canonical serialized form (see
  [schema-pipeline.md](schema-pipeline.md)).
- `schema_kind` — the top-level `Scroll` kind.

Commit the snapshot file to your repository. The digest is stable across
runs and across machines as long as the schema's semantics are unchanged.

### Checking against a snapshot

```sh
nyanform check \
  --snapshot _snapshots/server.json \
  --stdio-command node \
  --stdio-arg server.js
```

`check` fetches the live tool list, recomputes each tool's digest, and
classifies every difference:

| Classification | Meaning | Exit code contribution |
|----------------|---------|------------------------|
| `compatible` | A new tool appeared that was not in the snapshot. | non-breaking |
| `metadata_only` | Only the description changed; the schema digest is otherwise equal (re-parsed ignoring `description`). | non-breaking |
| `potentially_breaking` | The schema changed but digest comparison was inconclusive (e.g. one side failed to compile). | non-breaking (but flagged) |
| `breaking` | A tool was removed, or a schema digest changed. | **exit 1** |

`check` exits 1 if any change is classified as `breaking`. Wire this into
CI to catch unintended schema drift in your MCP server:

```yaml
- name: Detect schema drift
  run: |
    ./nyanform check \
      --snapshot _snapshots/server.json \
      --stdio-command node \
      --stdio-arg server.js
```

### Snapshot purity

Snapshots are JSON and contain only schema data and digests — never
arguments, environment values, or secrets. They are safe to commit and
diff in pull requests. When a schema change is intentional, regenerate
the snapshot and commit it alongside the schema change.
