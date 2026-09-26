# MCP TDQS lint gate and hosted score

_Last verified: 2026-09-26 (mcp-tdqs@0.2.0, `mcp-tools.json` 17 tools, spec 1.3; issue #1767)_

## What This Is

TDQS (Tool Definition Quality Score) checks the committed `mcp-tools.json` snapshot of
Engram's MCP tool surface. Read this before touching an MCP tool definition, or before the
TDQS lint job goes red.

## What is gated now

### Lint (gates `verify.yml`'s `lint` job)

```bash
npx -y mcp-tdqs@0.2.0 lint --file mcp-tools.json --server-name engram --fail-on warning
```

Recorded baseline (2026-09-26, 17 tools, specification 1.3):

```
0 errors, 0 warnings, 0 notes
```

Every tool reports `coverage 100%`, `annotations yes`, `output schema yes`. This is
deterministic (TDQS stages 1, 2, and 4): no model call, no API key. It checks for a missing
description, missing annotations, uncovered parameters, and shadowing names.

### Snapshot drift check (gates `verify.yml`'s `lint` job)

`mcp-tools.json` is the committed `tools/list` payload, generated from
`Engram.MCP.Tools.wire_list/0`. CI regenerates it to a temp file and diffs against the
committed copy (same pattern as the `openapi.json` drift check); a mismatch fails the build
with `mcp-tools.json is stale. Run: mix engram.mcp.tools_json`.

To regenerate locally after changing a tool definition:

```bash
mise exec -- mix engram.mcp.tools_json
```

Then re-run the lint command above before committing: a tool definition change that adds a
missing description or annotation can move the lint result.

## Model scoring: no CI job, hosted report instead

There is no in-repo model-graded score workflow and no `ANTHROPIC_API_KEY` CI secret for
TDQS. The model-graded score comes from the tdqs.dev / Glama hosted report, which reads the
server's public tool listing after each prod release. Glama resyncs at least daily; use its
Sync button for an immediate re-score after a release that changes tool descriptions.

This keeps the deterministic lint as the only CI gate on tool definitions, with no per-run
model cost and no secret to manage.

## Related

- `docs/context/ci-pipeline-gating.md`: what gates `verify.yml` today and why
- Issue #1767: MCP tool surface phase 1 (this doc's task)
- `.github/workflows/verify.yml` (`lint` job)
