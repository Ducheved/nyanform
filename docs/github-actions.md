# GitHub Actions

The checked-in workflow is `.github/workflows/ci.yml`. It runs for pushes to
`main` and pull requests targeting `main`, using Elixir 1.20 and OTP 29 on
`ubuntu-latest`.

## Repository jobs

The workflow is a dependency graph, not one serial list:

| Job | Depends on | What it runs |
|---|---|---|
| `quality` | none | Dependency/build caches, `mix deps.get`, warning-free compilation, formatting, the no-comments task, Credo strict, the regular tests, then the suite with property tests included. |
| `dialyzer` | none | Dependency/build/PLT caches, dependency fetch, compilation, and `mix dialyzer`. |
| `escript` | `quality`, `dialyzer` | Builds the escript, runs `--help`, runs fixture-backed `inspect`, sends an initialize request through stdio serve mode, packages the executable, and uploads a seven-day artifact. |
| `docker` | `quality` | Builds the Docker image without pushing it and runs the image with `--help`. |

The workflow requests only `contents: read`. It does not publish a release,
push a container image, configure branch protection, or upload SARIF.

Local aliases cover the Mix checks:

- `mix quality` runs formatting, warning-free compilation, the no-comments
  task, Credo strict, and the regular tests.
- `mix ci` runs formatting, warning-free compilation, the no-comments task,
  Credo strict, tests with the property tag included, and Dialyzer.

The escript and Docker smoke tests are additional workflow steps rather than
part of either Mix alias.

## Using matrix output in another workflow

`nyanform matrix` supports terminal, JSON, JUnit, and SARIF output. A repository
that has GitHub Code Scanning available can generate and upload SARIF, for
example:

```yaml
permissions:
  contents: read
  security-events: write

steps:
  - name: Run compatibility matrix
    run: |
      ./nyanform matrix \
        --stdio-command node \
        --stdio-arg server.js \
        --format sarif \
        --output nyanform.sarif

  - name: Upload SARIF
    uses: github/codeql-action/upload-sarif@v3
    with:
      sarif_file: nyanform.sarif
```

This is an integration example, not behavior configured by Nyanform's own CI.
Repository plan, event type, fork permissions, and GitHub settings determine
whether an upload is accepted and displayed.

The SARIF renderer emits SARIF 2.1.0 with one run. It creates rules for the
diagnostic codes encountered in that matrix result, and maps Nyanform
severities as follows:

| Nyanform severity | SARIF level |
|---|---|
| `exact` | `none` |
| `normalized` | `note` |
| `lossy` | `warning` |
| `rejected` | `error` |

The renderer currently writes `0.1.0` in the SARIF driver metadata because that
value is hard-coded in the renderer. It should not be interpreted as proof of
a published `v0.1.0` release.

### Matrix exit behavior

| Flag | Default | Effect |
|---|---:|---|
| `--fail-on-rejected` | `true` | Exit non-zero if a result is rejected. Use `--no-fail-on-rejected` to disable it. |
| `--fail-on-lossy` | `false` | Exit non-zero when lossy diagnostics are present if the flag is enabled. |

For a gate that fails on both rejected and lossy projections:

```sh
./nyanform matrix \
  --stdio-command node \
  --stdio-arg server.js \
  --fail-on-rejected \
  --fail-on-lossy
```

## Snapshot-based checks

`snapshot` fetches selected upstream initialization data and every paginated
`tools/list` page, up to `max_tool_count`, then writes a JSON document:

```sh
./nyanform snapshot \
  --stdio-command node \
  --stdio-arg server.js \
  --output _snapshots/server.json
```

The document currently contains selected initialization fields (`serverInfo`,
capabilities, and protocol revision) and, for each tool, its name, description,
input schema, output schema, input-schema digest, and top-level schema kind. It
is not a byte-for-byte catalog capture.

The digest is computed from the canonical `Scroll` form. The serializer strips
paths and selected non-semantic metadata such as descriptions, titles,
defaults, examples, and raw fallback data before hashing. Consequently, a
change limited to those fields may leave the digest unchanged. Server info,
capabilities, descriptions, and input/output schemas retain their raw upstream
values. The digest and top-level schema kind are derived. Tools are sorted by
name, and canonical comparison semantics apply to the digest.

Compare a live upstream with a stored file using:

```sh
./nyanform check \
  --snapshot _snapshots/server.json \
  --stdio-command node \
  --stdio-arg server.js
```

Current classifications are:

| Classification | Current condition | Affects exit code |
|---|---|---:|
| `compatible` | A tool exists live but not in the stored snapshot. | no |
| `metadata_only` | The tool description changed while the input comparison matches after dropping its top-level description and the output comparison matches. | no |
| `potentially_breaking` | At least one input digest is unavailable and the input/output comparisons do not both match. | no |
| `breaking` | A stored tool disappeared, or both input digests are available and either the input or output comparison differs. | yes |

`check` exits non-zero only when at least one `breaking` change is present.
Review `potentially_breaking` results explicitly rather than treating a zero
exit code as proof of compatibility.

### Snapshot confidentiality

Snapshots do not record tool-call arguments or the configured upstream
environment. They are still not automatically safe to commit: raw server
metadata fields, descriptions, and schemas can contain secrets in defaults, examples,
annotations, enum/const values, or vendor extensions. Nyanform does not run
`redact_secrets/2` over snapshot data.

Inspect and sanitize each generated file according to the upstream's data
classification before storing it in version control or uploading it as an
artifact.
