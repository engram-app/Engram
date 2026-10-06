# Context Doc: Web-app i18n foundation

_Last verified: 2026-10-04_

## Status

Foundation and all ten translated catalogs shipped, and the language switcher is always visible (the temporary `import.meta.env.DEV` gate is gone).

**Translations are LLM-generated and have not been reviewed by native speakers.** Glossary references (UI nouns such as "vault", "note", "sync") were taken from the Obsidian plugin's locale files and the marketing site's locale files, so terminology matches those surfaces. Expect tone and terminology slips, especially in `ja`, `ko`, `zh-*`, `ru`; do not market a language as supported without review.

## What exists

All under `frontend/src/i18n/`:

- `locales.ts`: `LOCALES` (11 codes, `en` plus ten translated), `LOCALE_NAMES` (each in its own language), `matchLocale`/`resolveLocale` (browser tags to a supported locale; `zh-TW/HK/MO/Hant` map to `zh-TW`, other `zh` to `zh-CN`, `pt` to `pt-BR`).
- `locale-provider.tsx`: `LocaleProvider` and `useT()` returning `{ locale, setLocale, t, tn }`. Mounted in `main.tsx` directly inside `ThemeProvider`. Sets `<html lang>` to `renderedLocale` (the locale once its catalog has keys; all ten now do; failed loads stay `en`), lazy-loads the catalog chunk via `import.meta.glob`, reports a failed load to Sentry and keeps English.
- `translate.ts`, `trans.tsx` (`<Trans text slots>` for sentences around React children), `storage.ts` (`engram:locale` in localStorage).
- `locale/<code>.ts`: ten catalogs (no `en`).
- `keys.test.ts`: the drift guard.

Proof surface: the Language `<select>` in its own card, Settings > Account > Language (`language-section.tsx`, rendered after Appearance; a shadcn `Select`; always visible), and the 404 page (`not-found.tsx`).

## The model: English is the key

`t("Page not found")` returns the catalog entry for that exact English string, or the string itself if there is none. Consequences:

- There is **no `en` catalog**. English is the source text in the code, so it can never drift from a file that duplicates it. A missing translation is the designed fallback, not an error.
- Un-wrapped trees (and tests that predate i18n) get an English identity `useT()`, not a throw.
- Placeholders are `{name}`; the key carries them, so catalogs must keep the same set.

## Why no URL prefix (`/de/...`)

The SPA is behind auth and has no SEO surface; the locale is a per-device preference like theme. A prefix would touch every route and link for no benefit. Precedence: stored pick, then `navigator.languages`, then `en`.

## Rules

- **Call `useT()` only inside components/hooks.** No module-scope `t()` (it would freeze English at import time and ignore the locale). For module-level constants use `msg()` (see Marking strings).

- **`t`/`tn` change identity** whenever a catalog loads or the language switches. Never leave them in the dependency array of an effect, callback or memo that must NOT re-run then: a refetch effect would fire again and a late response could overwrite a setting the user just flipped. Use `useStableT()` (`locale-provider.tsx`): same `{ t, tn }`, identities fixed, always calling the latest translator. Only inside handlers, promise handlers, `.catch`, toasts and such effects, never while rendering (its ref catches up in a layout effect, after the render that switched language). Memoized RENDER output (a labels array, a filtered list of translated rows) keeps `t` as a dependency so it updates on a language switch.
- The scanner cannot see a call through an alias, so write it `const { t: tLater } = useStableT()` and `tLater(msg("..."))`: `msg()` marks the key. `keys.test.ts` fails on a literal passed to `tRef.current(`, `x.t(`, or a `tName(` alias.

## Marking strings

The scanner (`src/i18n/keys-scan.ts`, shared by `keys.test.ts` and `i18n:missing`) is regex-based, so a key must be a **literal double-quoted string on the call site**:

- `t("Save changes")`, `t("Hello {name}", { name })`: component code, via `useT()`.
- `tn({ one: "{count} file", other: "{count} files" }, n, { count: n })`: counted strings. The key is the `other` form; `one` is shown to translators. The object may span lines.
- `<Trans text="Type {w}" slots={{...}} />`: a sentence around React children. Plain `text="..."` only, not `text={"..."}`.
- `msg("Settings")` (`src/i18n/msg.ts`): returns the string unchanged and marks it as a key. Use it for labels in module-scope constants, then render with `t(item.label)`.

Not allowed (the scanner cannot see them, so the string is never tracked or translated): template literals, concatenation (`"a" + b`), `t(variable)` on an unmarked variable, single-quoted or `{"..."}`-wrapped literals. Keep escapes JSON-valid (`\"`).

## Add a string

1. Wrap it: `t("Save changes")`, `tn(...)` for counts, `<Trans text>` around React children, or `msg(...)` in module-scope constants (see Marking strings).
2. Run `cd frontend && bun run i18n:missing -- --count` to see what each locale lacks.
3. Translate every locale (all ten `locale/*.ts`), keeping `{placeholders}` identical.
4. `bunx vitest run src/i18n` : `keys.test.ts` fails on cross-locale gaps (parity), orphans and placeholder mismatches. `--count` all zero means done.

## Add a locale

1. Add `src/i18n/locale/<code>.ts` (full catalog; the Biome filename override covers `pt-BR.ts`-style names).
2. Add the code to `LOCALES` and its native name to `LOCALE_NAMES` in `src/i18n/locales.ts` (plus any `matchLocale` mapping for browser tags).
3. Add the Clerk and Paddle mappings in `src/i18n/vendor-locales.ts`.
4. Biome: `biome.json` already disables `useFilenamingConvention` for `src/i18n/locale/*.ts`; a new code needs no change unless the glob is narrowed.
5. Run `i18n:missing -- --count` and the vitest suite; the parity test requires the new file to hold every key.

## Add a plural

The key is the English `other` form, with forms keyed by `Intl.PluralRules` categories:

```tsx
tn({ one: "{count} file", other: "{count} files" }, n, { count: n })
```

Catalog entry: `"{count} files": { one: "…", other: "…" }` (add `few`/`many` etc. where the language needs them).

## i18n:missing (for translators)

`cd frontend && bun run i18n:missing` scans `src/**/*.{ts,tsx}` (not tests or `src/i18n/locale/`) with the same scanner and compares against each `locale/*.ts` catalog. It is a report, always exit 0.

- `bun run i18n:missing`: JSON `{ locales, total, missing: { <code>: [{ key, plural? }] } }`.
- `bun run i18n:missing --locale de`: only that locale's missing entries, as a JSON array.
- `bun run i18n:missing --count`: `code: missingCount` per locale.

Translate each `key` (keep every `{placeholder}` identical). For an entry with `plural`, the catalog value is an object keyed by `Intl.PluralRules` categories (`one`, `other`, plus `few`/`many` where the language needs them); `plural.one` shows the singular source. Add the same keys to all ten catalogs (`keys.test.ts` fails on cross-locale gaps); `--count` all zero means done.

## How `keys.test.ts` guards drift

It scans source for `t`, `msg`, `tn` (`other`) and `<Trans text>` keys, then fails on: an **orphan** key (in a catalog, not used in source), a **placeholder mismatch** (dropped or invented `{name}`), and a **cross-locale gap** (key present in one catalog, absent in another). The placeholder check covers `{placeholder}` tokens only; `<Trans>` slots use the same `{slot}` syntax, so they are covered. Used keys with no catalog entries at all are tolerated by the guard, but every locale now carries every key (`i18n:missing --count` is all zero).

## Clerk and Paddle follow the rendered locale

Both follow `renderedLocale` from `useT()` (the selected locale once its app catalog has keys, else `"en"`; the same value `<html lang>` uses), NOT the raw `locale`. This keeps Clerk and Paddle from going foreign over an English app if a catalog is empty or fails to load. All ten catalogs have keys now.

- **Mapping:** `src/i18n/vendor-locales.ts`. Paddle codes equal ours except `zh-CN` -> `zh-Hans`.
- **Clerk:** `<ClerkProvider localization>` in `clerk-auth-provider.tsx`. Catalogs come from `@clerk/localizations` as one lazy chunk per language (literal dynamic imports; a variable specifier would not bundle). English, loading and a failed load all leave `localization` undefined (Clerk's English), failures go to `captureError`. `@clerk/react` pushes a changed `localization` prop into the mounted instance, so no remount. Clerk marks localization experimental. `@clerk/localizations` is pinned to 4.17.0: newer minors require `@clerk/shared` >= 4.34, but this repo overrides `@clerk/shared` to the 4.33 that `@clerk/react` uses.
- **Paddle:** the locale is applied per `paddle.Checkout.open(...)`, NOT in the `initializePaddle` effect. That effect rebuilds the Paddle instance and strands an open checkout (same reason the theme is fixed), so it must not depend on the locale. `checkoutSettings(isInline)` in `billing-page.tsx` builds the shared settings from stable inputs only; init uses it with `locale: "en"` as the default, and each open (new checkout and the `transactionId` payment-update open) passes `{ ...checkoutSettings(isInline), locale }` in FULL. Reason: Paddle.js's merge of partial per-open `settings` over the init defaults is undocumented, and this is the payments path, so we never depend on it.
- **Clerk pin:** `@clerk/localizations` stays at 4.17.0 because the repo's `@clerk/shared` override holds 4.33 (4.21.x needs >= 4.38), so a dependabot bump to 4.21.x needs the override lifted first. Strings added to Clerk's UI after 4.17 show in English.
- **Not covered:** the hosted Clerk Account Portal, and everything Paddle hosts (customer portal, receipts, invoices, emails).

## Biome

`biome.json` turns `useFilenamingConvention` off for `src/i18n/locale/*.ts` because codes like `pt-BR.ts` and `zh-CN.ts` are not kebab-case. Biome also enforces `useExportsLast` and a no-unsafe-type-assertion rule here; narrow with `isMember` (`lib/is-member.ts`) instead of `as`.

## Done and still owed

- Slices 1-4 shipped: foundation, app shell, notes/editor/search, ten translated catalogs, switcher visible.
- Owed: native-speaker review of the catalogs, and consider a "beta" label on the switcher until then.
