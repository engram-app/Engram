# Context Doc: Web-app i18n foundation

_Last verified: 2026-10-04_

## Status

Slice 1 (foundation) shipped. No shell/feature strings are wrapped yet and every non-English catalog is an empty stub, so every locale renders English today.

## What exists

All under `frontend/src/i18n/`:

- `locales.ts`: `LOCALES` (11 codes), `LOCALE_NAMES` (each in its own language), `matchLocale`/`resolveLocale` (browser tags to a supported locale; `zh-TW/HK/MO/Hant` map to `zh-TW`, other `zh` to `zh-CN`, `pt` to `pt-BR`).
- `locale-provider.tsx`: `LocaleProvider` and `useT()` returning `{ locale, setLocale, t, tn }`. Mounted in `main.tsx` directly inside `ThemeProvider`. Sets `<html lang>`, lazy-loads the catalog chunk via `import.meta.glob`, reports a failed load to Sentry and keeps English.
- `translate.ts`, `trans.tsx` (`<Trans text slots>` for sentences around React children), `storage.ts` (`engram:locale` in localStorage).
- `locale/<code>.ts`: ten catalogs (no `en`).
- `keys.test.ts`: the drift guard.

Proof surface: the Language `<select>` in Settings > Account > Appearance, and the 404 page (`not-found.tsx`).

## The model: English is the key

`t("Page not found")` returns the catalog entry for that exact English string, or the string itself if there is none. Consequences:

- There is **no `en` catalog**. English is the source text in the code, so it can never drift from a file that duplicates it. A missing translation is the designed fallback, not an error.
- Un-wrapped trees (and tests that predate i18n) get an English identity `useT()`, not a throw.
- Placeholders are `{name}`; the key carries them, so catalogs must keep the same set.

## Why no URL prefix (`/de/...`)

The SPA is behind auth and has no SEO surface; the locale is a per-device preference like theme. A prefix would touch every route, link and the OAuth/device-flow redirects for no benefit. Precedence: stored pick, then `navigator.languages`, then `en`.

## Rules

- **Call `useT()` only inside components/hooks.** No module-scope `t()` (it would freeze English at import time and ignore the locale). For module-level constants, store the English string and call `t(constant)` at render. Note `keys.test.ts` only sees string literals inside `t("...")`, so a constant needs its literal wrapped somewhere `t("...")` appears, or it will not be tracked.
- Keep the English literal on one line inside `t(...)`; the scanner is regex-based.

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

It scans source for `t("…")`, `tn({… other: "…"})` and `<Trans text="…">`, then fails on: an **orphan** key (in a catalog, not used in source), a **placeholder mismatch** (dropped or invented `{name}`), and a **cross-locale gap** (key present in one catalog, absent in another). Used keys with no catalog entries at all are fine, which is why stubs stay green.

## Biome

`biome.json` turns `useFilenamingConvention` off for `src/i18n/locale/*.ts` because codes like `pt-BR.ts` and `zh-CN.ts` are not kebab-case. Biome also enforces `useExportsLast` and a no-unsafe-type-assertion rule here; narrow with `isMember` (`lib/is-member.ts`) instead of `as`.

## Still owed

- **Slice 2:** wrap the app shell (nav, settings, onboarding, auth screens, toasts, errors).
- **Slice 3:** notes, editor, search.
- **Slice 4:** actually translate the ten catalogs.

## Risk: translations will be machine-made

Slice 4 translations will be LLM-generated with no native-speaker review. Expect tone and terminology slips (UI nouns like "vault", "note", "sync"), especially in `ja`, `ko`, `zh-*`, `ru`. Do not market a language as supported without review, and consider a "beta" label on the switcher until then.
