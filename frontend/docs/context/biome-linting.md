# Frontend Biome Linting Setup + Gotchas

Read this before touching `frontend/biome.json` or the `frontend-lint` CI job.

## What's set up

- **Biome 2.5.1** (lint + formatter) in `frontend/`, pinned **EXACTLY** in
  `package.json` (`"@biomejs/biome": "2.5.1"` — no caret). See gotcha §2 for why.
- Scripts (mirror engram-marketing): `lint` / `lint:fix` / `format` / `check` /
  `check:fix` / `ci`. `ci` runs `biome ci .` (biome's `ci` mode errors on warnings).
- **CI gate:** `frontend-lint` job in `.github/workflows/verify.yml` runs
  `bun run ci`, path-gated to `frontend/` (early-exits if `git diff origin/main`
  shows no `frontend/` change). Wired into the `ci` aggregate gate's `needs` list
  and its required-jobs loop (`frontend-lint=$FL`), so a lint/format failure
  blocks merge.

## Ruleset philosophy — curated max-strict

Every rule group is enabled at `error` via bulk group-severity strings in
`linter.rules` (`"style": "error"`, `"nursery": "error"`, etc.) on top of
`"recommended": true`. A **single global override** (`overrides[0]`, `includes: ["**"]`)
then turns two sets back off:

- **(a) Permanently off** — framework-wrong rules: `noReactSpecificProps` (wants
  `class` not `className`), plus React Native / Solid / Qwik / Next.js rules Biome's
  nursery pulls in; and React/TS-hostile rules (`noTernary`, `noJsxLiterals`,
  `useExplicitType`/`useExplicitReturnType`, `noMagicNumbers`, `noNonNullAssertion`,
  `useNamingConvention` — the API is **snake_case**, so this would fight every DTO).
- **(b) Ratchet-deferred** — real rules the current code violates, to be re-enabled
  one-per-PR. Tracked in **engram-app/Engram issue #812**.

There is no per-rule comment distinguishing (a) from (b) in the file — see gotcha §1.
Intent lives in #812 and commit messages.

## Gotchas (the expensive ones)

1. **A `//` comment INSIDE an `overrides[]` object silently drops the whole
   override** in Biome 2.5.1 — no parse error, the disabled rules just start
   applying again (often surfacing at a surprising `warn` severity). **Keep the
   overrides array comment-free.** Document intent in #812 / commit messages, never
   inline.

2. **Nursery rules move between Biome minors.** 2.4.15 → 2.5.1 relocated
   `noTernary`, `noHexColors`, `useGlobalThis`, `noJsxPropsBind`,
   `noExcessiveLinesPerFile` to different groups (they now live under `style` /
   `performance`, not `nursery`). A silent caret bump therefore breaks CI. **This is
   why Biome is pinned exact.** After any *intentional* bump, run
   `bunx biome migrate --write` to re-home moved rules, then re-verify.

3. **Blanket `biome check --write --unsafe` HANGS** on this codebase. Apply unsafe
   fixes **rule-by-rule**, each time-boxed:
   ```bash
   bunx biome check --write --unsafe --only=<group>/<rule> .
   ```

4. **Some unsafe autofixes are semantically wrong** — exclude and hand-check:
   - `noEqualsToNull` rewrites `x == null` (null **and** undefined) → `x === null`
     (null only), leaking `undefined` past guards.
   - `noImplicitCoercions` rewrites `!!x` → `Boolean(x)`, dropping TS type-narrowing.
   **Always run `bunx tsc --noEmit` after any unsafe fix** (see
   `strict-tsc-and-test-typechecking.md` — tsc is the authoritative check; vitest
   won't catch this).

5. Biome 2.5.1 uses `"preset": "recommended"` if you regenerate config; `migrate`
   renames the older `recommended: true` form.

## Re-enabling a ratchet rule (the workflow)

1. Pick a rule (or one cohesive group) from **issue #812**.
2. Delete it from `overrides[0]` in `biome.json`.
3. `bun run lint:fix`, then hand-fix residual violations (apply the unsafe-fix
   caveats in §3/§4 as needed).
4. Confirm `bun run ci` **and** `bunx tsc --noEmit` are both green.
5. One rule / cohesive group **per PR** — don't batch unrelated rules.
