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

6. **`bun run ci` can't find `biome` locally** — the `ci` script calls bare `biome`,
   which resolves via `node_modules/.bin` only in CI. To run the same gate locally
   use `npx @biomejs/biome ci .` (or `bunx`). Same for one-off rule checks:
   `npx @biomejs/biome lint --only=<group>/<rule> --max-diagnostics=none .`.

7. **Most ratchet rules have NO autofix in 2.5.1 — plan for hand-fixing.** Verified
   with `--write` and `--write --unsafe`: `useExportsLast`, `useImportsFirst`,
   `useDestructuring`, `useNamedCaptureGroup`, and `noVoid` all report *"No fixes
   applied."* — every site is hand-fixed. `lint:fix` does nothing for them. (The
   `organizeImports` **assist** does re-sort, which matters for §8.) Measure a rule's
   scope up front: `npx @biomejs/biome lint --only=<group>/<rule> --max-diagnostics=none . | grep -E "^Found"`.

## Per-rule notes (learned while ratcheting — see #812)

- **`useNamedCaptureGroup`** — a captured group must be named or made non-capturing.
  Unused (match-only) groups → `(?:...)`. Groups read by index (`m[1]`, `?.[1]`) or
  by a `replace` positional callback → add a name (`(?<x>...)`); named groups stay
  **index-accessible** in JS, so `m[1]` keeps working — no call-site change needed.
- **`useDestructuring`** — `const x = obj.x` → `const { x } = obj`; a single index read
  (`arr[0]`, `token.split(".")[1]`) → array destructure (`const [x] = arr`,
  `const [, base64] = ...`). Assignment to an outer `let` → `({ x } = obj)` (needs
  parens).
- **`useImportsFirst`** — imports must precede any other statement. Almost all
  violations are vitest tests where imports sit after `vi.mock`/`vi.hoisted`. vitest
  **hoists `vi.mock` to the top regardless of source order**, so moving the trailing
  imports above the mocks is behavior-preserving. Do NOT reorder the mock factories or
  their module-scope bindings. Verify with the **full** `vitest run` (mock ordering).
- **`useExportsLast`** — all exported declarations must sit at the end. Reorder so
  non-exports come first, exports last. TDZ risk: moving a `const`/`let`/`class` above
  a binding it references throws at runtime. `function` decls hoist (safe);
  `interface`/`type` are compile-erased (safe). Guard: after reordering run
  `tsc --noEmit` and grep for `error TS2448|2454|2449` (use-before-declaration) — must
  be zero — plus a full `vitest run`.
- **`noVoid` is behavioral here, not mechanical** — every site is the deliberate
  floating-promise idiom (`void promise().catch(...)`, `void logout()`,
  `void import(...)`). Removing `void` either leaves an unhandled floating promise or
  forces `await` (changes the caller). Handle it in the behavioral tier, not as a
  mechanical sweep.

## Re-enabling a ratchet rule (the workflow)

1. Pick a rule (or one cohesive group) from **issue #812**.
2. Measure scope (§7) and delete the rule from `overrides[0]` in `biome.json`.
3. Try `npx @biomejs/biome lint --write [--unsafe] --only=<group>/<rule> .`; expect
   NO autofix for the rules in §7 — hand-fix the sites (apply the §3/§4 caveats and
   the per-rule notes above).
4. If you moved imports, run `npx @biomejs/biome check --write .` once to let the
   `organizeImports` assist re-sort the moved blocks (§8 territory).
5. Confirm `npx @biomejs/biome ci .` **and** `npx tsc --noEmit` **and** the affected
   (or full) `npx vitest run` are all green.
6. One `mix.exs` version bump **per PR** (frontend is a deployable path → the
   `version-check` gate). One rule / cohesive group per PR — don't batch unrelated
   rules.

## Progress (as of 2026-07-01)

Mechanical tier **complete**: `noLeakedRender` (#826), `useNamedCaptureGroup` (#827),
`useDestructuring` (#828), `useImportsFirst` (#830), `useExportsLast` (#831), on top of
the earlier a11y tier. Remaining in #812: the **behavioral tier** (`noVoid`,
`useExhaustiveDependencies`, `noEqualsToNull`, `noUnnecessaryConditions`, `useAwait`,
`noShadow`, `noEmptyBlockStatements`, `noReturnAssign` — autofixes change semantics,
hand-review each) and config-gated `useAtIndex` (its `.at(-1)` autofix needs a tsconfig
`lib` → es2022 bump in the same PR).
