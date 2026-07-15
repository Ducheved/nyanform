---
name: Bug report
about: Report something that is broken or behaves unexpectedly
title: "[bug] "
labels: bug
---

## Summary

A one- or two-sentence description of what is wrong.

## Steps to reproduce

1.
2.
3.

If you can, include the exact `nyanform` command you ran and a minimal
upstream MCP server or schema that triggers the issue.

## Expected behavior

What you expected to happen.

## Actual behavior

What actually happened. Paste the relevant diagnostic output (omens,
error codes) or the terminal output verbatim.

```
(paste output here)
```

## Environment

- Nyanform source revision (`git rev-parse HEAD`) or artifact provenance:
- Elixir version (`elixir -v`):
- OTP version:
- Operating system:
- Profile selected:
- Policy:
- Upstream transport (stdio / http):
- Downstream transport (stdio / http):

## Output of `nyanform doctor`

`doctor` reports runtime and configured catalog information. It does not report
the Nyanform Git revision or prove that the Elixir/OTP versions satisfy
`mix.exs`, so keep the environment fields above.

```
(paste nyanform doctor output)
```

## Schema or payload

If the bug involves a specific schema or JSON-RPC payload, paste it here.
Remove secrets manually before posting. Automatic redaction is not applied to
issue text, snapshots, schemas, descriptions, defaults, examples, annotations,
enum/const values, or vendor extensions.

Do not file exploitable vulnerability details or credentials in a public issue.
Read `SECURITY.md` first; the repository currently does not promise a private
reporting channel or response SLA.
