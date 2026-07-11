# Context Doc: Bun lifecycle-script trust (pngquant-bin CI flake fix)

_Last verified: 2026-07-08 (bun 1.3.11, against `frontend/package.json`; issue #975, PR #981)_

## What This Is

Why `bun install --frozen-lockfile` was flaky on cold-node_modules frontend CI jobs, and what we
learned about bun's lifecycle-script trust model fixing it. Read this before touching
`trustedDependencies` or re-adding a package with a network-fetching postinstall.

## The Problem (#975)

- `pngquant-bin`'s postinstall downloads its binary from GitHub. The CI runner pool's shared
  egress IP gets 429'd, and the download bypasses the local `:4873` NPM mirror entirely.
- The source-build fallback dies on missing `pkg-config`/`libimagequant`.
- Net effect: any frontend job with a cold `node_modules` failed at install time.
- The binary is only used by `frontend/scripts/render-email-mark.ts` — a one-shot script whose
  output is committed. Nothing at build/test time needs it.

## The Fix (PR #981)

`trustedDependencies` in `frontend/package.json`, pinned to today's actually-needed postinstall
set minus `pngquant-bin`, then pruned to the entries that actually run (`esbuild`, `msw`,
`workerd` — `core-js`/`protobufjs` never execute under bun 1.3.11 listed or not, so listing
them only misrepresented the trust surface) — which blocks
its lifecycle script.

## Bun trust semantics (learned empirically, bun 1.3.11)

- Bun ships a ~366-package default-trusted list (`bun pm default-trusted`). It includes
  `pngquant-bin` and `esbuild`. Only those packages' lifecycle scripts run by default.
- Setting `trustedDependencies` can EXCLUDE a default-trusted package: with the field present,
  `pngquant-bin`'s postinstall no longer ran.
- But packages NOT on the default list stayed blocked even when named in `trustedDependencies`,
  at least for the transitive deps we observed (`core-js`, `protobufjs` remained in
  `bun pm untrusted` output both before and after). Don't trust docs from memory — verify with
  `bun pm untrusted` after a cold install.
- `bun pm untrusted` lists blocked scripts. `@clerk/shared`, `core-js`, `@sentry/cli`,
  `protobufjs` were ALREADY blocked on main before this change (pre-existing, harmless).

## Verification recipe (the A/B that proved it)

In a worktree: `rm -rf node_modules && bun install --frozen-lockfile` WITHOUT the change
reproduces the CI failure verbatim (`error: postinstall script from "pngquant-bin" exited with 1`
— the GitHub fetch fails locally too when it 429s, or it succeeds and writes
`node_modules/pngquant-bin/vendor/pngquant`). WITH the change the same cold install succeeds and
`vendor/` has no binary. Then `bun run build` proves esbuild etc. survived.

## Running render-email-mark.ts locally

`bun pm trust pngquant-bin && bun install` once, then run the script.

## Related

- `docs/context/runner-vm-setup.md` — shared egress / registry proxy
- Issue #975, PR #981
