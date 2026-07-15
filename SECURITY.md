# Security Policy

## Reporting a vulnerability

This repository does not currently advertise a verified private vulnerability
mailbox or a response-time SLA. Do not assume that GitHub private vulnerability
reporting is enabled, and do not open a public issue containing exploit details,
credentials, private schemas, or other sensitive material.

For a non-sensitive hardening problem, a public issue is appropriate. For a
sensitive vulnerability, contact the repository owner through a verified
GitHub channel first and agree on a private channel before sending details. If
no private channel is available, retain the sensitive details until one is
established.

Once a private channel has been agreed, useful report context includes:

- The impact and minimal reproduction.
- The relevant MCP configuration, schema, or JSON-RPC payload with unrelated
  secrets removed.
- The exact source revision or artifact provenance, plus `elixir -v` output.
- `nyanform doctor` output as additional environment context. `doctor` reports
  the running Elixir version and checks configured protocol/profile data; it
  does not identify the Nyanform release or Git commit.
- Whether the issue affects schema compilation, profile projection, session
  lifecycle, transport behavior, configuration, or the CLI.

No acknowledgement, remediation, embargo, private-branch, or release timeline
is guaranteed by this policy.

## Scope

Nyanform sits between an MCP client and an MCP server and treats data from both
sides as untrusted. Relevant security issues include:

- Bypassing an active message-size, schema-depth, local-reference traversal,
  downstream HTTP body-size, matrix-concurrency, or upstream request-timeout
  boundary.
- Memory exhaustion or unbounded recursion caused by malicious frames or
  schemas.
- Command or argument injection in the stdio transport. The current transport
  launches an executable directly with Erlang ports and does not invoke a
  shell.
- Non-JSON-RPC output written by Nyanform to stdout in stdio mode.
- Secret leakage in configuration errors, diagnostics, logs, snapshots, or
  reports.
- Data crossing session boundaries.

`max_tool_count` is enforced for live session catalogs and for full-catalog CLI
fetches. The default is 1024 entries. `max_diagnostic_count` exists in
`Nyanform.Limits`, but diagnostic accumulators do not enforce it, so it must not
be treated as a security boundary.

The following remain operator responsibilities:

- Authentication and authorization for clients and upstream servers. Nyanform
  does not provide either.
- Exposure beyond the default loopback HTTP binding.
- TLS termination and reverse-proxy configuration.
- Reviewing snapshot contents. Snapshots omit tool-call arguments, but retain
  raw server metadata, tool descriptions, input schemas, and output schemas.
  Secrets embedded in descriptions, defaults, examples, annotations, or
  extensions are not automatically redacted.

See [docs/security.md](docs/security.md) for the implemented controls and their
limits.

## Supported versions

No version tag or GitHub Release has been published. The `0.1.0` value in
`mix.exs` is package metadata only. Security fixes, when made, are applied to
the current source branch; there is no published release line with a declared
support window.

## Coordination

Maintainers may coordinate validation, fixes, disclosure timing, and reporter
credit after a usable private channel exists. Any such coordination is
case-specific and is not a standing SLA or release guarantee.
