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

- Nyanform version:
- Elixir version (`elixir -v`):
- OTP version:
- Operating system:
- Profile selected:
- Policy:
- Upstream transport (stdio / http):
- Downstream transport (stdio / http):

## Output of `nyanform doctor`

```
(paste nyanform doctor output)
```

## Schema or payload

If the bug involves a specific schema or JSON-RPC payload, paste it here.
Redact any secrets first (Nyanform redacts known secret keys, but please
double-check).
