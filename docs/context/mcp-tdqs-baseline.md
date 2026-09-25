# Context Doc: MCP TDQS baseline and gating rule

_Last verified: 2026-09-25 (mcp-tdqs@0.2.0, `mcp-tools.json` 21 tools, spec 1.3; issue #1767)_

## What This Is

TDQS (Tool Definition Quality Score) checks the committed `mcp-tools.json` snapshot of
Engram's MCP tool surface. Two layers exist: a deterministic lint (gates CI today) and a
model-graded score (report-only, not yet running). Read this before touching an MCP tool
definition, before the TDQS lint or score job goes red, or before flipping the score job
from report-only to gating.

## What is gated now

### Lint (gates `verify.yml`'s `lint` job)

```bash
npx -y mcp-tdqs@0.2.0 lint --file mcp-tools.json --server-name engram --fail-on warning
```

Recorded baseline (2026-09-25, 21 tools, specification 1.3):

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

## Model scoring

`.github/workflows/mcp-tdqs-score.yml` runs `mcp-tdqs@0.2.0 score` against `mcp-tools.json`
whenever it changes on `main`/`feat/**`/`fix/**`/`refactor/**`/`docs/**`, plus manual dispatch.
It is report-only (`continue-on-error: true`) and gates nothing yet.

- **Model + endpoint:** `claude-haiku-4-5-20251001` via Anthropic's OpenAI-compatible endpoint
  (`TDQS_BASE_URL=https://api.anthropic.com/v1/`). `TDQS_REQUEST_OVERRIDES='{"max_tokens":4096}'`
  is required because that endpoint rejects a request with no `max_tokens`, which mcp-tdqs
  does not send by default.
- **Env vars:** `TDQS_API_KEY` (job-level, sourced from the `ANTHROPIC_API_KEY` secret; also
  doubles as the skip switch, since a step's own `env:` is not visible to its own `if:`),
  `TDQS_BASE_URL`, `TDQS_MODEL`, `TDQS_REQUEST_OVERRIDES`.
- **Cost per run:** about 22 model calls, about 52K tokens, about $0.12 on Haiku 4.5, one
  `score --format json` invocation, since `tdqs score` renders exactly one format per run.

**The secret does not exist yet.** The workflow's `Check for ANTHROPIC_API_KEY` step emits
`::notice::ANTHROPIC_API_KEY not set, skipping score` and every later step is conditioned on
the secret being non-empty, so the job goes green-but-empty on every run so far. No score data
exists. To add the secret:

```bash
gh secret set ANTHROPIC_API_KEY -R engram-app/Engram
```

### OpenRouter fallback

If the Anthropic OpenAI-compatible endpoint rejects the request shape mcp-tdqs sends (beyond
the known missing-`max_tokens` case already patched via `TDQS_REQUEST_OVERRIDES`), fall back to
routing the same model through OpenRouter: set `TDQS_BASE_URL=https://openrouter.ai/api/v1/`,
`TDQS_MODEL` to OpenRouter's Haiku 4.5 slug, and `TDQS_API_KEY` to an `OPENROUTER_API_KEY`
secret instead of `ANTHROPIC_API_KEY`. Not implemented; only needed if the Anthropic endpoint
proves incompatible once a key is added.

## The gating rule (not yet adopted)

Once `ANTHROPIC_API_KEY` exists, run the score workflow three times against `main` and record
each run's overall score, tier, and per-tool spread (max minus min per tool, per dimension) in
a new section below. Only after those 3 runs are recorded here does the following rule take
effect:

- Gate on the server score: `mcp-tdqs@0.2.0 score --file mcp-tools.json --fail-under B` (or
  whichever tier the 3 baseline runs land on).
- Additionally fail if the overall score drops more than 0.3 below the recorded baseline
  average.
- If the measured spread across the 3 runs exceeds 0.3, widen the drop margin to match the
  measured spread instead of tightening it artificially: the gate must not flap on model
  variance alone.

This rule is adopted only once 3 runs are recorded here. Until then, `mcp-tdqs-score.yml`
stays report-only and this section is the entire gating policy: none.

## External reference (not comparable)

Glama's public listing scores Engram's MCP server A (4.1/5) as of 2026-09-25, with a callout
of Usage Guidelines 2/5 on `write_note` and `patch_note`. That score comes from an undisclosed
model with an undisclosed rubric, so it is not comparable to the mcp-tdqs number produced here
and should not be used as a stand-in baseline or as evidence the local gate is redundant.

## Related

- `docs/context/ci-pipeline-gating.md`: what gates `verify.yml` today and why
- Issue #1767: MCP tool surface phase 1 (this doc's task)
- `.github/workflows/mcp-tdqs-score.yml`, `.github/workflows/verify.yml` (`lint` job)
