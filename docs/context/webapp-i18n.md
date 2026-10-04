# Context Doc: Web-app i18n foundation

_Last verified: 2026-10-04_

## Status

Slice 1 (foundation) shipped. No shell/feature strings are wrapped yet and every non-English catalog is an empty stub, so every locale renders English today.

## What exists

All under `frontend/src/i18n/`:

- `locales.ts`: `LOCALES` (11 codes), `LOCALE_NAMES` (each in its own language), `matchLocale`/`resolveLocale` (browser tags to a supported locale; `zh-TW/HK/MO/Hant` map to `zh-TW`, other `zh` to `zh-CN`, `pt` to `pt-BR`).
- `locale-provider.tsx`: `LocaleProvider` and `useT()` returning `{ locale, setLocale, t, tn }`. Mounted in `main.tsx` directly inside `ThemeProvider`. Sets `<html lang>` to the locale only once a non-empty catalog is rendered (empty stubs and failed loads stay `en`), lazy-loads the catalog chunk via `import.meta.glob`, reports a failed load to Sentry and keeps English.
- `translate.ts`, `trans.tsx` (`<Trans text slots>` for sentences around React children), `storage.ts` (`engram:locale` in localStorage).
- `locale/<code>.ts`: ten catalogs (no `en`).
- `keys.test.ts`: the drift guard.

Proof surface: the Language `<select>` in Settings > Account > Appearance (shown in dev builds only until slice 4 ships translations; `import.meta.env.DEV` gate), and the 404 page (`not-found.tsx`).

## The model: English is the key

`t("Page not found")` returns the catalog entry for that exact English string, or the string itself if there is none. Consequences:

- There is **no `en` catalog**. English is the source text in the code, so it can never drift from a file that duplicates it. A missing translation is the designed fallback, not an error.
- Un-wrapped trees (and tests that predate i18n) get an English identity `useT()`, not a throw.
- Placeholders are `{name}`; the key carries them, so catalogs must keep the same set.

## Why no URL prefix (`/de/...`)

The SPA is behind auth and has no SEO surface; the locale is a per-device preference like theme. A prefix would touch every route and link for no benefit. Precedence: stored pick, then `navigator.languages`, then `en`.

## Rules

- **Call `useT()` only inside components/hooks.** No module-scope `t()` (it would freeze English at import time and ignore the locale). For module-level constants, store the English string and call `t(constant)` at render. Note `keys.test.ts` only sees string literals inside `t("...")`, so a constant needs its literal wrapped somewhere `t("...")` appears, or it will not be tracked.
- Keep the English literal on one line inside `t(...)`; the scanner is regex-based. It matches `<Trans text="...">` only with a plain double-quoted literal, not `text={"..."}` or template literals.

## Add a string

1. Wrap it: `t("Save changes")`, or `t("Hello {name}", { name })`.
2. Add the entry to each `locale/*.ts` catalog (the test requires all-or-none, see below).

## Add a plural

The key is the English `other` form, with forms keyed by `Intl.PluralRules` categories:

```tsx
tn({ one: "{count} file", other: "{count} files" }, n, { count: n })
```

Catalog entry: `"{count} files": { one: "…", other: "…" }` (add `few`/`many` etc. where the language needs them).

## How `keys.test.ts` guards drift

It scans source for `t("…")`, `tn({… other: "…"})` and `<Trans text="…">`, then fails on: an **orphan** key (in a catalog, not used in source), a **placeholder mismatch** (dropped or invented `{name}`), and a **cross-locale gap** (key present in one catalog, absent in another). The placeholder check covers `{placeholder}` tokens only; `<Trans>` slots use the same `{slot}` syntax, so they are covered. Used keys with no catalog entries at all are fine, which is why stubs stay green.

## Clerk and Paddle follow the rendered locale

Both follow `renderedLocale` from `useT()` (the selected locale only once its app catalog has keys, else `"en"`; the same value `<html lang>` uses), NOT the raw `locale`. Otherwise a ja browser would get Japanese sign-in and checkout over an all-English app until slice 4.

- **Mapping:** `src/i18n/vendor-locales.ts`. Paddle codes equal ours except `zh-CN` -> `zh-Hans`.
- **Clerk:** `<ClerkProvider localization>` in `clerk-auth-provider.tsx`. Catalogs come from `@clerk/localizations` as one lazy chunk per language (literal dynamic imports; a variable specifier would not bundle). English, loading and a failed load all leave `localization` undefined (Clerk's English), failures go to `captureError`. `@clerk/react` pushes a changed `localization` prop into the mounted instance, so no remount. Clerk marks localization experimental. `@clerk/localizations` is pinned to 4.17.0: newer minors require `@clerk/shared` >= 4.34, but this repo overrides `@clerk/shared` to the 4.33 that `@clerk/react` uses.
- **Paddle:** the locale is applied per `paddle.Checkout.open(...)`, NOT in the `initializePaddle` effect. That effect rebuilds the Paddle instance and strands an open checkout (same reason the theme is fixed), so it must not depend on the locale. `checkoutSettings(isInline)` in `billing-page.tsx` builds the shared settings from stable inputs only; init uses it with `locale: "en"` as the default, and each open (new checkout and the `transactionId` payment-update open) passes `{ ...checkoutSettings(isInline), locale }` in FULL. Reason: Paddle.js's merge of partial per-open `settings` over the init defaults is undocumented, and this is the payments path, so we never depend on it.
- **Clerk pin:** `@clerk/localizations` stays at 4.17.0 because the repo's `@clerk/shared` override holds 4.33 (4.21.x needs >= 4.38), so a dependabot bump to 4.21.x needs the override lifted first. Strings added to Clerk's UI after 4.17 show in English.
- **Not covered:** the hosted Clerk Account Portal, and everything Paddle hosts (customer portal, receipts, invoices, emails).

## Biome

`biome.json` turns `useFilenamingConvention` off for `src/i18n/locale/*.ts` because codes like `pt-BR.ts` and `zh-CN.ts` are not kebab-case. Biome also enforces `useExportsLast` and a no-unsafe-type-assertion rule here; narrow with `isMember` (`lib/is-member.ts`) instead of `as`.

## Still owed

- **Slice 2:** wrap the app shell (nav, settings, onboarding, auth screens, toasts, errors).
- **Slice 3:** notes, editor, search.
- **Slice 4:** actually translate the ten catalogs.

## Risk: translations will be machine-made

Slice 4 translations will be LLM-generated with no native-speaker review. Expect tone and terminology slips (UI nouns like "vault", "note", "sync"), especially in `ja`, `ko`, `zh-*`, `ru`. Do not market a language as supported without review, and consider a "beta" label on the switcher until then.
