# Context Doc: Web-app i18n foundation

_Last verified: 2026-10-11_

## Status

Foundation and all twelve translated catalogs shipped (`vi` and `ms` added 2026-10-11 for signups from Vietnam and Malaysia), and the language switcher is always visible (the temporary `import.meta.env.DEV` gate is gone).

**Translations are machine-generated (translategemma since 2026-10-11, see Automated translation) and have not been reviewed by native speakers.** Glossary references (UI nouns such as "vault", "note", "sync") were taken from the Obsidian plugin's locale files and the marketing site's locale files, so terminology matches those surfaces. Expect tone and terminology slips, especially in `ja`, `ko`, `zh-*`, `ru`; do not market a language as supported without review.

## What exists

All under `frontend/src/i18n/`:

- `locales.ts`: `LOCALES` (13 codes, `en` plus twelve translated), `LOCALE_NAMES` (each in its own language), `matchLocale`/`resolveLocale` (browser tags to a supported locale; `zh-TW/HK/MO/Hant` map to `zh-TW`, other `zh` to `zh-CN`, `pt` to `pt-BR`).
- `locale-provider.tsx`: `LocaleProvider` and `useT()` returning `{ locale, setLocale, t, tn }`. Mounted in `main.tsx` as the outermost element, above `RootErrorBoundary` and the top-level `Suspense`, so `ErrorFallback` and `LoadingScreen` translate too (`main.locale-wiring.test.ts` guards it). Sets `<html lang>` to `renderedLocale` (the locale of the catalog actually on screen). The LAST SUCCESSFULLY LOADED catalog stays rendered until a newly selected language's chunk resolves, then swaps atomically, so a switch never drops to English in between; a failed, `undefined` or empty load keeps the previous catalog and is reported to Sentry (the picker then shows the selected `locale` over the old `renderedLocale`). Selecting `en` (no loader) switches at once. Chunks load lazily via `import.meta.glob`.
- `translate.ts`, `trans.tsx` (`<Trans text slots>` for sentences around React children), `storage.ts` (`engram:locale` in localStorage).
- `locale/<code>.ts`: twelve catalogs (no `en`).
- `keys.test.ts`: the drift guard.

Proof surface: the Language `<select>` in its own card, Settings > Account > Language (`language-section.tsx`, rendered after Appearance; a shadcn `Select`; always visible), and the 404 page (`not-found.tsx`).

## Typed text: UIText and MsgKey (tsc is the main gate)

`src/i18n/ui-text.ts`. Raw English reaching the user is a **type error**, which also covers what no regex can see (a literal returned from a helper, a custom prop, a variable):

- `UIText`: branded string. Only `t`/`tn` (via `interpolate`) and `untranslated(text)` produce it. UI text props (`SettingsSectionCard` title, `HelpTip` label, onboarding/billing copy, ...) and `notify()` take it.
- `notify()` (`src/lib/notify.ts`) is the only toast API; Biome `noRestrictedImports` bans importing sonner's `toast` outside it and tests. It forwards exactly the arguments given, so `vi.mock("sonner")` assertions keep working.
- `untranslated(text)`: the explicit exception for text we show as-is: backend `ApiError.message`, Clerk API errors (English; only Clerk's components are localized), tool brand names. `grep -rn "untranslated(" src` lists every exception.
- `MsgKey`: what `msg()` returns. Module-scope label arrays (`settings/sections.ts`, `tree-actions/action-list.ts`, `billing/limit-copy.ts`, `feedback/options.ts`, ...) type their fields as `MsgKey`, so a raw `label: "Foo"` (invisible to the scanner, so never translated) fails tsc. A field that mixes keys and already-translated labels is `MsgKey | UIText` (`Action.label`).
- Props that carry user data (note and connection names, property keys, ids) stay `string`. When the types were introduced each candidate prop was retyped alone and tsc showed what flows in: `t()` output means UI copy, `msg()` means a key holder, everything else is data.
- Brands are built by a type predicate, not `as`: shipped code lints type assertions.

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

Raw JSX text (`<p>Save</p>`) is a lint error: Biome's `style/noJsxLiterals` is on in `biome.json`, with an `allowedStrings` list for symbols and brand names (`·`, `×`, `/`, `Engram`, `PayPal`, ...) and an override turning it off for `**/*.test.tsx` and `src/dev/**` (DEV-only routes). A genuinely untranslatable string goes on the allowlist, not behind a suppression. Attribute strings are not Biome-linted (the rule's `noStrings` option would also flag every `className`); instead `keys.test.ts` "has no raw English in user-facing attributes" fails on a literal `placeholder`, `aria-label`, `aria-description`, `title`, `alt` or `label` outside tests and `src/dev`, with its own small allowlist. A second test, "has no raw English passed to toasts, errors or dialogs", does the same for `toast*(`, `setError(`/`setMessage(`, `confirm(`/`alert(` and `document.title =` in shipped `.ts`/`.tsx` (it caught two raw dev-checkout toasts in `billing-page.tsx` on 2026-10-11).

Not allowed (the scanner cannot see them, so the string is never tracked or translated): template literals, concatenation (`"a" + b`), `t(variable)` on an unmarked variable, single-quoted or `{"..."}`-wrapped literals. Keep escapes JSON-valid (`\"`).

## Add a string

1. Wrap it: `t("Save changes")`, `tn(...)` for counts, `<Trans text>` around React children, or `msg(...)` in module-scope constants (see Marking strings).
2. Run `cd frontend && bun run i18n:missing -- --count` to see what each locale lacks.
3. Run `bun run i18n:translate` (see Automated translation), or let the CI bot PR do it after merge. Hand-edit a catalog entry only to fix a bad translation.
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

## Automated translation (translategemma)

`cd frontend && I18N_OLLAMA_URL=http://10.0.20.214:11434 bun run i18n:translate` fills catalogs with `translategemma:12b` on FastRaid's Ollama. The pipeline is the shared core in `src/i18n/core/` (`core.ts`: prompt, cleanup, checks, gate, state; `run.ts`: the loop), vendored byte for byte into the plugin and marketing repos (`core/README.md`, `make i18n-core-sync`). `src/i18n/translate-profile.ts` is the web app's languages, register, brands and glossary; `scripts/i18n-translate.ts` is the file I/O.

- **Diff-only by default.** English is the key, so a new or edited string is a key the catalog lacks; only those are sent. Keys the source no longer uses are dropped (no orphans for `keys.test.ts`). `--all` retranslates everything (about 3h for twelve locales; run it after changing the prompt, glossary or model). `--locale vi,ms` limits the run.
- **Change detection needs no hash:** the English string is the key, so an edited string is a new key and its old one an orphan. Planning all 12 locales (scan 339 files, diff 1,183 keys) takes ~0.4 s; model time is spent only on changed strings. The exception is a plural, keyed by its `other` form: `state.json` records each plural's English `one` form (`one`), and a mismatch retranslates the entry.
- **Self-healing on translator changes:** each locale in `locale/state.json` carries a fingerprint of the prompt (built for fixed probe strings), the profile and the Ollama model digest (`/api/tags`; `ollama pull` can move a tag). A mismatch redoes the locale, so nobody bumps a version: the old `TRANSLATOR_VERSION` was missed in three commits. The stamp is written per locale, so a run killed by the CI timeout resumes on the next one.
- **Failed keys are tracked, with a deadline:** `state.json` `failed` maps each key whose answer failed every check to the day it first failed. The gate tolerates a listed key (it keeps a valid old entry or shows English); the script exits 1 once one is older than `I18N_STUCK_DAYS` (14), which fails the nightly bot. Without this, one untranslatable key failed the bot's parity step before the PR step every night, and the whole run's output was lost.
- **Where results live:** in git. The catalogs and `locale/state.json` are the store, so CI needs no cache or artifact. Until the bot PR merges, progress lives on `bot/i18n-translate`. A run with an OPEN bot PR passes its `locale/` dir as `--resume`: the script reuses its entries only for keys this run would translate, and only if the same fingerprint built them. Copying the whole directory over main (the old way) reverted catalog and state changes merged since the branch was cut. Each catalog is formatted the moment it is written, so a killed run still passes `biome ci`. A timed-out or failed translate step still saves the PR, then fails the job ("Fail if translation did not finish"), so an Ollama outage is never green.
- **CI:** `.github/workflows/i18n-translate.yml` runs on every main push touching `frontend/src/**` (not the catalogs) and opens/updates the signed bot PR `bot/i18n-translate`. A full pass needs no dispatch input: a fingerprint change triggers it, and the nightly resumes it. Runners reach Ollama through the runner VM allowlist (port 11434 on FastRaid).
- **Prompt:** the model's own template plus a UI-context line, a fixed glossary (the locale's current `Vaults`, `Attachments`, `Folder`, `Settings`, `Search`, and a sentence that sets the register; a new locale gets gemma's own term first, then it is held fixed) and the register rule per language: `de`/`es`/`fr`/`it` informal, `ru` formal `вы`, `pt-BR` `você`, `vi` `bạn`, `ms` `anda`. Without the glossary the model rendered "vault" as Tresor/Speicherbereich/金庫/セーフティボックス in one run and switched German to Sie.
- **Placeholder masking:** names are swapped for `{0}`, `{1}` before sending and restored after (`mask`; tags become `<0>…</0>` too). Unmasked, the model translates word-like names (`{used}` -> `{digunakan}`, `{recoverable}` -> `{dipulihkan}`), every retry fails the placeholder check and the string stays English, which breaks the cross-locale parity test.
- **Glossary source of truth:** the profile's `glossary` (core product terms: Note, Vault(s), Sync, Attachments, Folder, Tags, Backlinks, Properties, Wikilink, Connections, Settings, Search) are pinned to each catalog's current value and never sent to the model. Their values come from Obsidian's official UI translations (`obsidianmd/obsidian-translations`, `translations/<code>.txt`), so our words match the app users already know; `de`..`zh-TW` keep the terms reviewed in the original catalogs. For a new locale, copy the terms from that repo into the catalog BEFORE the first run (vi/ms were done this way on 2026-10-11). Unpinned, gemma drifted on exactly these: fr "Backlinks" -> "Liens entrants", ja -> "参照ノート", ms "Sync" -> "Sejajarkan" ("align"). `keys.test.ts` fails if a glossary entry is not a real key (an unused "Notes" pinned nothing). A term is never retranslated, even on a redo; editing one redoes every sentence that uses it (`glossaryStale`, via `state.json` `glossary`).
- **Never spell a placeholder in the prompt:** the rules once said "Copy every {placeholder} ...", and for placeholder-free text (a plural sample "2 days left") gemma pasted a literal `{placeholder}` into the answer, so every retry failed and the string stayed English. Rules that mention a token (placeholders, ⏎) are stated only when the text has one, and name no token (`buildPrompt` test). Same for glossary emoji: terms are sent without them, or the model pastes 🔄 into every sentence (`symbols` check, found in the plugin).
- **Brand and plan names are masked, not just listed:** "Starter" and "Pro" are brand terms (they must match Paddle checkout and invoices; "Free" describes the price and is translated). gemma translated them even when told not to ("Choose Starter" -> "选择入门版"), so `mask` swaps every brand word (whole word: "Pro" is not "Profile") for a numbered token like a placeholder. A string that is only brands ("Pro") is copied as-is with no model call. The brand check allows an inflected `s` ("Obsidians Stil").
- **New checks heal old entries:** every run also retranslates committed entries that fail today's checks (`invalidKeys`), so adding a rule (a brand, a register) fixes existing violations on the next run. An entry that `cleanOutput` alone repairs (lost edge spaces, bled `<0>` tokens) is fixed with no model call.
- **Batching:** 12 numbered strings per request, 2 concurrent (about 2.5x faster than one per request; the model keeps the numbering). A line that is missing or fails a check is retried alone at temperature 0, 0.3, 0.6.
- **Acceptance checks** (`problems`): same `{placeholder}` set and tags, no invented numbered token, same newline count, the source's edge spaces kept (not in `ja`/`zh`), URLs/code spans/e-mails and brand names kept, no runaway length, no wrong-register pronouns, the expected script for `ja`/`ko`/`zh`/`ru`, and no English echo (a phrase of 3+ words, or one word over a real old translation). The translator and the gate call the same function; the old entry may only ADD a check, never waive one, so the bot cannot write what the gate rejects (the old waivers did exactly that). A string that never passes keeps its old translation, or stays English (the designed fallback) for a new key.
- **Plurals:** each `Intl.PluralRules` category is translated from a concrete number (`5 files` for `ru` many, `1.5` for a fraction-only `other`), then the number is swapped back to `{count}`, so the model picks the case form. If any category fails, the whole entry keeps its old forms.
- **Per-PR gate, no model:** `src/i18n/catalog-quality.test.ts` runs core `catalogProblems` (missing keys, orphans, plural shape per `Intl.PluralRules`, every `problems()` check) over every committed catalog inside the normal vitest job (well under a second), plus `sourceProblems` (a plural without `{count}` cannot be sampled: `{n} notes` shipped Russian `few` = `many`). With `keys.test.ts` (scanner guards) it is the fast translation check; the gemma run itself only happens on main. The script check applies only to sentences of more than 3 words, so `ID:` or `A → Z` may stay Latin in `ja`/`ko`/`zh`; a plural `one` form may drop `{count}`.
- **Output** is written per locale when that locale finishes (resume a killed `--all` with `--locale` for the rest) and formatted with `bun run biome format`.

## Email (backend)

Every email is written in the recipient's language. `Engram.I18n` maps
`users.locale` (BCP 47, reported by the web app and plugin) onto the same 13
locales, English when unset or unknown. Catalogs are
`priv/i18n/email/<locale>.json`, compiled into `Engram.I18n` at build time.

- **Add an email string:** write it as a `t(l, "...")` call with a literal key
  (it may span lines) in `lib/engram/mailer.ex`, or `I18n.t(locale, "...")` in
  `lib/engram/email/template.ex`. No HTML inside a key; `{name}` placeholders
  only. `frontend/src/i18n/email-keys.ts` finds keys by that shape and skips
  whole-line `#` comments.
- **Legal changelogs** in `lib/engram/legal/seeder.ex` are keys too, so the
  "what changed" line arrives translated. Word them so a short word cannot be
  read two ways: "Note content is never sent" came back in German as "take
  note that content is never sent".
- `bun run i18n:translate` runs the email catalogs first (a few dozen keys, so a
  web run that hits the step timeout cannot starve them), then the web
  catalogs, with one profile. The nightly bot carries both; `email-keys.test.ts` is the PR gate.
- A missing key ships in English until the bot fills it. Dates: "November 11,
  2026" in English, ISO 8601 elsewhere (no CLDR dependency).
- The linked legal documents themselves stay English only.

## i18n:missing (for translators)

`cd frontend && bun run i18n:missing` scans `src/**/*.{ts,tsx}` (not tests or `src/i18n/locale/`) with the same scanner and compares against each `locale/*.ts` catalog. It is a report, always exit 0.

- `bun run i18n:missing`: JSON `{ locales, total, missing: { <code>: [{ key, plural? }] } }`.
- `bun run i18n:missing --locale de`: only that locale's missing entries, as a JSON array.
- `bun run i18n:missing --count`: `code: missingCount` per locale.

Translate each `key` (keep every `{placeholder}` identical). For an entry with `plural`, the catalog value is an object keyed by `Intl.PluralRules` categories (`one`, `other`, plus `few`/`many` where the language needs them); `plural.one` shows the singular source. Add the same keys to all ten catalogs (`keys.test.ts` fails on cross-locale gaps); `--count` all zero means done.

## How `keys.test.ts` guards drift

It scans source for `t`, `msg`, `tn` (`other`) and `<Trans text>` keys, then fails on: an **orphan** key (in a catalog, not used in source), a **placeholder mismatch** (dropped or invented `{name}`), and a **cross-locale gap** (key present in one catalog, absent in another). The placeholder check covers `{placeholder}` tokens only; `<Trans>` slots use the same `{slot}` syntax, so they are covered. Used keys with no catalog entries at all are tolerated by the guard, but every locale now carries every key (`i18n:missing --count` is all zero).

## Clerk and Paddle follow the rendered locale

Both follow `renderedLocale` from `useT()` (the locale of the catalog on screen, `"en"` before any loads; the same value `<html lang>` uses), NOT the raw `locale`. This keeps Clerk and Paddle in step with the app text, never flickering through English on a switch and never going foreign over an app whose catalog failed to load.

- **Mapping:** `src/i18n/vendor-locales.ts`. Paddle codes equal ours except `zh-CN` -> `zh-Hans`, and `vi`/`ms` -> `en` (Paddle checkout offers neither). Clerk has both (`vi-VN`, `ms-MY`).
- **Clerk:** `<ClerkProvider localization>` in `clerk-auth-provider.tsx`. Catalogs come from `@clerk/localizations` as one lazy chunk per language (literal dynamic imports; a variable specifier would not bundle). English, loading and a failed load all leave `localization` undefined (Clerk's English), failures go to `captureError`. `@clerk/react` pushes a changed `localization` prop into the mounted instance, so no remount. Clerk marks localization experimental. `@clerk/localizations` is pinned to 4.17.0: newer minors require `@clerk/shared` >= 4.34, but this repo overrides `@clerk/shared` to the 4.33 that `@clerk/react` uses.
- **Paddle:** the locale is applied per `paddle.Checkout.open(...)`, NOT in the `initializePaddle` effect. That effect rebuilds the Paddle instance and strands an open checkout (same reason the theme is fixed), so it must not depend on the locale. `checkoutSettings(isInline)` in `billing-page.tsx` builds the shared settings from stable inputs only; init uses it with `locale: "en"` as the default, and each open (new checkout and the `transactionId` payment-update open) passes `{ ...checkoutSettings(isInline), locale }` in FULL. Reason: Paddle.js's merge of partial per-open `settings` over the init defaults is undocumented, and this is the payments path, so we never depend on it.
- **Clerk pin:** `@clerk/localizations` stays at 4.17.0 because the repo's `@clerk/shared` override holds 4.33 (4.21.x needs >= 4.38), so a dependabot bump to 4.21.x needs the override lifted first. Strings added to Clerk's UI after 4.17 show in English.
- **Not covered:** the hosted Clerk Account Portal, and everything Paddle hosts (customer portal, receipts, invoices, emails).

## Biome

`biome.json` turns `useFilenamingConvention` off for `src/i18n/locale/*.ts` because codes like `pt-BR.ts` and `zh-CN.ts` are not kebab-case. Biome also enforces `useExportsLast` and a no-unsafe-type-assertion rule here; narrow with `isMember` (`lib/is-member.ts`) instead of `as`.

## Validation (browser level)

Playwright specs in `frontend/e2e/` prove that language selection and catalog coverage work in a real browser. They do NOT prove translation quality (an LLM-generated string passes as long as it differs from the English key).

| Spec (project) | What it checks |
|---|---|
| `i18n-detection.spec.ts` (`local`) | Each of the twelve browser locales (`de-DE` ... `zh-TW`, including `vi-VN` and `ms-MY`) lands on the right `<html lang>` and shows the catalog's own "Sign in to Engram" heading. Fallbacks: `en-GB` -> `en`, `zh-HK` -> `zh-TW`, `pt-PT` -> `pt-BR`, unsupported `nl-NL` -> `en`. A stored `engram:locale=ja` beats a `de-DE` browser; an unknown stored value is ignored. The Settings > Account picker switches `<html lang>` and text without a reload and the pick survives one (this test registers a user, tagged `[registers user]`). |
| `i18n-onboarding.spec.ts` (`local`, self-host) | Per locale: sign-up, tools, tools with the opt-out ticked, vault, vault > Obsidian panel, vault > starting fresh, dashboard, Settings > Account. |
| `i18n-onboarding-clerk.spec.ts` (`clerk`, SaaS) | Same walk, plus agreement and billing, with Clerk's `.cl-rootBox` excluded from the scan; the Clerk sign-up screen's title must equal `@clerk/localizations`' string for the locale. Needs `E2E_CLERK_SECRET_KEY`, skipped without it. |

At every onboarding step (`support/i18n-leaks.ts` `checkStep`): `<html lang>` equals the locale; **leaks** (a visible string, or `placeholder`/`aria-label`/`title`/`alt`, exactly equal to an English key that the locale's catalog really translates; `{placeholder}` keys match as wildcards) FAIL the test; **suspects** (non-Latin locales only: a visible all-ASCII string of more than 3 words once brand names, URLs, e-mails and numbers are removed, i.e. probably unwrapped English) are only reported. Leaks are soft assertions, so one bad step does not hide the rest. Brand and technical tokens (Engram, Obsidian, MCP, API, Paddle, Clerk) never count.

Pure matching logic is in `e2e/support/i18n-leaks-core.ts`, unit-tested by `src/lib/i18n-leaks-core.test.ts` (Vitest ignores `e2e/`).

### Run

```bash
cd frontend
bunx playwright test --project=local e2e/i18n-detection.spec.ts e2e/i18n-onboarding.spec.ts
# no user is created by the detection spec alone:
bunx playwright test --project=local e2e/i18n-detection.spec.ts --grep-invert "registers user"
```

The registering specs create `i18n-e2e-<ts>-<locale>@test.com` users and delete each one afterwards through `DELETE /api/me` (`deleteAccount` in `support/api.ts`; it cascades notes, which `db-cleanup.ts`'s single `DELETE` cannot, because of the notes FK). **Run them only against a disposable database** (CI's per-run Postgres, or `make saas-dev`, which recreates its DB). `make dev-selfhost` talks to the persistent FastRaid Postgres shared with the deployed self-host, whose sign-up also needs an invite; do not point them at it. `db-cleanup.ts` additionally sweeps the `i18n-e2e-%` pattern when `DATABASE_URL` is a localhost URL.

### Read the output

- Screenshots: attached to each test as `<locale>-<step>` (e.g. `ja-vault-fresh`), in the HTML report (`bunx playwright show-report`) or under `test-results/<test>/`. Look for English text, clipped strings, and layout broken by long German or Russian words.
- `<locale>-<step>-findings` (JSON attachment): `{ leaks, suspects }` for that step.
- Suspects also appear as test annotations (`i18n-suspects <locale>-<step>`). A suspect is a prompt to look, not a failure: legal text (Terms of Service) and server-provided strings are legitimately English.
- A failing leak names the key: find it with `grep -rn '"<key>"' src --include=*.tsx`, then fix the catalog (the string is wrapped but that locale's entry is missing or equal to English).

### Local box notes

Headless Chromium may be missing for the pinned Playwright build; see `headless-chromium-no-raf-playwright.md` (xvfb headed fallback). The pinned build number in `node_modules` can differ from the browsers in `~/.cache/ms-playwright`; a throwaway config that sets `use.launchOptions.executablePath` to an installed build works without touching the repo config.

## Done and still owed

- Slices 1-4 shipped: foundation, app shell, notes/editor/search, ten translated catalogs, switcher visible.
- Owed: native-speaker review of the catalogs, and consider a "beta" label on the switcher until then.
