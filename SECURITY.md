# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities privately rather than opening a
public issue.

Email: **security@ducheved.dev**

Include the following when you report:

- A description of the issue and its potential impact.
- Steps to reproduce, including any minimal MCP server configuration,
  schema, or JSON-RPC payload that triggers the issue.
- The Nyanform version (`nyanform doctor` output) and the Elixir/OTP
  versions you ran against.
- Whether the issue is in the schema compiler, the proxy lifecycle, the
  transports, or the CLI.

You should receive an initial response within 72 hours. Please do not
disclose the issue publicly until a fix has been released and you have
been given the all-clear.

## Scope

Nyanform sits between an MCP client and one or more MCP servers. Both
sides are treated as untrusted. The following are considered in scope:

- Bypass of any resource limit (message size, schema depth, reference
  depth, HTTP body size, request timeout).
- Memory exhaustion or unbounded recursion triggered by a malicious
  upstream schema, client frame, or tool argument.
- Command injection or argument injection in the stdio transport (Nyanform
  spawns upstream servers via Erlang ports and `:spawn_executable`; any
  path that reaches a shell is a vulnerability).
- stdout protocol corruption in stdio mode (anything written to stdout
  that is not a valid JSON-RPC frame).
- Secret leakage in diagnostics, logs, snapshots, or reports.
- Session isolation violations (one session's data leaking into another).

The following are considered **out of scope** under default configuration:

- Attacks against clients or servers that Nyanform proxies. Nyanform does
  not authenticate or authorize either side; it is a transparent proxy.
- Network exposure of the HTTP downstream when the operator has not
  changed the default `127.0.0.1` binding.
- TLS termination, which is the operator's responsibility (run Nyanform
  behind a TLS-terminating reverse proxy).

See [docs/security.md](docs/security.md) for the full defense-in-depth
model.

## Supported versions

Nyanform is pre-1.0 and currently in active development. Only the latest
release line receives security fixes.

| Version | Supported |
|---------|-----------|
| 0.1.x   | yes       |
| < 0.1   | no        |

## Disclosure policy

1. We acknowledge receipt of the report within 72 hours.
2. We investigate and confirm the vulnerability, then develop and test a
   fix on a private branch.
3. We coordinate a release date with the reporter, typically within 14
   days of confirmation for high-severity issues.
4. We publish a patched release and credit the reporter (unless they
   prefer to remain anonymous) in the release notes and
   [CHANGELOG.md](CHANGELOG.md).
