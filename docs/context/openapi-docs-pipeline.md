# OpenAPI docs pipeline

_First cut shipped in PR #649 (2026-06-19). Health endpoints only; remaining ~100 REST endpoints annotated incrementally._

## What & where

`open_api_spex ~> 3.21` (resolved 3.22.3) generates an OpenAPI 3.0 spec.

| File | Purpose |
|------|---------|
| `lib/engram_web/api_spec.ex` | Root document — `EngramWeb.ApiSpec`, implements `OpenApiSpex.OpenApi` |
| `lib/engram_web/schemas.ex` | Reusable schema modules (`EngramWeb.Schemas.*`) |
| `openapi.json` | Committed spec at repo root — the source of truth |

Served at `GET /api/openapi` via `pipeline :openapi` in `router.ex`:
```elixir
plug OpenApiSpex.Plug.PutApiSpec, module: EngramWeb.ApiSpec
# → OpenApiSpex.Plug.RenderSpec
```

The marketing site (`engram-marketing`) renders this spec.

## Adding an endpoint to the docs

1. Add `use OpenApiSpex.ControllerSpecs` to the controller module.
2. Add one `operation :action_name, summary: "...", responses: [...]` macro per action, referencing schema modules in `EngramWeb.Schemas`.
3. Actions **without** an `operation` macro do NOT appear in the spec — that is the exclusion mechanism.
4. To **explicitly exclude** an action (e.g. admin-only): use `operation :action_name, false`. This is **required** — open_api_spex logs a runtime warning for every unannotated action on a controller that has `use OpenApiSpex.ControllerSpecs`.

Example (HealthController): `:index` and `:deep` are annotated; `:diagnostics` is excluded:
```elixir
operation :diagnostics, false
```

5. After annotating, regenerate and commit `openapi.json` (see below).

## Committed artifact + drift gate

`openapi.json` at repo root is the committed source of truth.

**To regenerate:**
```bash
mix openapi.spec.json --spec EngramWeb.ApiSpec --pretty=true openapi.json
```

The `unit-tests` CI job (`.github/workflows/verify.yml`) regenerates the spec and fails if it differs from the committed file. Always re-run the command above and commit the result after annotating endpoints.

## GOTCHA — new /api routes need the HostRewrite allowlist

Any new top-level `/api/<segment>` route MUST be added to `@api_top_segments` in `lib/engram_web/plugs/host_rewrite.ex`, or it silently 404s on `api.engram.page` in prod. There is a regression test (`HostRewriteTest`) that fails loudly if you forget.

The `openapi` segment had to be added during initial wiring — this is a real gotcha.

## info.version is the static API contract version

`info.version` is a hardcoded `@api_version` constant in `api_spec.ex` (currently `"1.0.0"`), **not** the app build version (`Application.spec(:engram, :vsn)`). This is deliberate: the repo's `version-check` CI job forces a `mix.exs` bump on *every* PR, so if the spec tracked the build version, `openapi.json` would change on every PR and the drift gate would false-fail on changes that touch no API surface. Bump `@api_version` only when the REST contract itself changes. (The running build version is still exposed at `GET /api/health`.)

Because the spec is env- and build-independent, regeneration is deterministic — no recompile dance needed even in worktrees with a shared `_build`.

## GOTCHA — openapi.json key order is alphabetical

`open_api_spex --pretty` sorts keys alphabetically, so `components` appears before `info`. Do NOT grep for `"version"` naively:

```bash
# WRONG — matches the static HealthStatus example string, not info.version
grep -m1 '"version"' openapi.json

# CORRECT
python3 -c "import json; print(json.load(open('openapi.json'))['info']['version'])"
```
