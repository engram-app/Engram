# translategemma i18n gotchas and override tools

Verified 2026-10-12. Applies to the shared core (`frontend/src/i18n/core/`, canonical here; vendored into plugin and marketing via `make i18n-core-sync`). See `frontend/src/i18n/core/README.md` for the core's rules.

## English echo (bug class, fixed)

- The core used to waive English echoed back for 1-2 word strings. Result: "Undo", "Wikilink", "Bug", Malay "Sync" shipped in English.
- Now `problems()` fails an echo (`untranslated`) at any length unless the phrase is in `LOANWORDS` for that base language (`code.split("-")[0]`).
- `LOANWORDS` entries must be sourced from Obsidian's obsidian-translations repo or VS Code's language packs. `"*"` holds proper names every language keeps.
- Matching is the whole phrase (letters only, lowercased). `"obsidian sync"` is under `"*"`, so "Obsidian Sync" passes, but "Sync" alone still fails in fr.
- A loanword never replaces a real translation (the `old !== undefined && old !== src` clause). To switch an entry to an English loanword: delete the old catalog entry, then rerun.

## What triggers a redo

| Change | Redoes |
|--------|--------|
| Add/edit a BRAND or GLOSSARY key | Whole locale (fingerprint moves). Marketing took ~1h for 10 locales. |
| Add/edit a `descriptions` note | Only that key |
| Add a `pinned` key | Nothing (outside the fingerprint by design) |

## Override tools (profile fields)

- `pinned`: per locale, keys kept exactly as committed; never sent to the model. Only pin a value copied from Obsidian's translation of the same string, or one provably right. Last resort.
- `descriptions`: keyed by the English. FormatJS message `description` / gettext translator comment. The string is sent alone with its note.

## translategemma behavior (measured)

Short, context-free labels get the wrong sense:

- "Strikethrough": it "Sottolineato" (underline), vi "Gạch chân"
- "Reading": ja "読み込み中" (loading)
- "Dismiss": de "Abbrechen" (cancel)
- "Redo": ms "Batalkan" (undo)
- marketing "SYNC": imperative verbs

Descriptions fixed some: es/ko/zh "Reading", ru/zh "Idea", the AI-prompt string in all 10 marketing locales.

A broad description pass BROKE others:

- ms "Light" -> "Ringan" (lightweight)
- de "Redo edit" -> "Wiederherstellen" (restore)
- "Quote" came back as `Quote" -> "Cita`, copying the prompt format. That arrow format (`->`, `=>` not in source) is now rejected by the `stray` check.

Rules:

- Keep only descriptions whose output you reviewed.
- Temperature 0: the model repeats the same wrong answer, so re-rolling rarely helps. Example: ru "ХРАЛИЩЕ" typo needed a pin.
- Long paragraphs keep meaning better than labels, but no check catches flipped pronouns (zh-TW "my memory of you" for "your memory of me", ru "you set" vs "I set") or register drift (ja お客様). Review by eye.

## Meaning check (2026-10-16, tr/pl/id)

The acceptance checks are structural: they cannot see a wrong meaning. Adding `tr`, `pl` and `id` shipped green and still held ~38 real meaning errors out of ~1,000 sentences. What found them:

- Run `gemma3:12b` as a judge over every sentence of 5+ words: "English: ... / <Language>: ... / reply OK or BAD: <meaning error>". Script lived in the session scratchpad; it is ~30 lines over `/api/generate`.
- The judge is NOISY: ~45% of its BAD verdicts were wrong (it flags fluent idiom, passive voice, synonyms). Use it to shortlist, then read every flagged pair yourself. Never act on a verdict unread.
- The FastRaid Ollama keeps ONE model in VRAM. A gemma3 request queues behind translategemma's `keep_alive` (30m) and times out. Unload first: `curl .../api/generate -d '{"model":"translategemma:12b","keep_alive":0}'`. Same in reverse before translating.

What it found, by cause:

| Cause | Example | Fix |
|-------|---------|-----|
| Ambiguous English source | "the open standard Engram follows" read as "the open standard, Engram" in ~12 of 15 locales; "soft-deletes" as "temporarily deletes"; "escaped" as cancelled/avoided | Reword the SOURCE plainly ("an open standard that Engram follows"). A `descriptions` note did NOT fix these and leaked into es/ja output ("{okf} es un enlace..."). |
| Placeholder roles are invisible | "next bill {total} on {renewal}": masking turns names into `{0}`/`{1}`, so tr/ja/ko swap amount and date, ko adds 원 or 년/월 | Unsolved by prompt (4 rewordings + a positional note all failed somewhere). Proper fix: render the amount and date as separately labeled values, not one sentence. |
| Wrong word sense | pl "device" -> "urząd" (an office); tr "snippets" -> "short notes" | Translator note for labels; delete the entry and rerun for one-offs |
| Negation flip | tr "Any property you add" -> "that you DON'T add", reproduced at temperature 0 | Reword ("Every property you add") |
| Brand masked mid-sentence | "Steps left to finish setting up Engram" -> "Engram in Engram" (id/ms/vi), "Engram steps" (pl/ru) | Drop the brand from short labels |
| Pronouns in the tone line | tr tone "(siz, sizin)": gemma pasted `{siz}` as a placeholder | Tone line names no pronoun ("Use polite, concise UI Turkish."); the `formal` regex still rejects `sen` |

Before a new locale ships: probe a candidate rewording across 6 languages first (mask + `buildPrompt` + `/api/generate`, ~1 min), then change the source.

## Adding a locale: loanword sourcing

- Echoes the model gets RIGHT still fail (`untranslated`) until listed: Polish "Status", "System", "Link"; Indonesian "Subtotal", "admin", "per". List them in `LOANWORDS` with a source.
- Find candidates mechanically: parse `obsidian-translations/translations/<code>.txt` and count, per word, how often the translation keeps the English word. Majority-kept = a sourced loanword.
- VS Code has no Indonesian language pack (`microsoft/vscode-loc` has cs de es fr it ja ko pl pt-BR ru tr zh-hans zh-hant). Indonesian "admin", "bug", "subtotal" are kept on the owner's call (comment in `core.ts`); KBBI was unreachable from the dev box.
- A `pinned` value must pass every check too: pinning an English echo does not excuse it. Only `LOANWORDS` does.

## Reference data

- Obsidian's translations: `https://raw.githubusercontent.com/obsidianmd/obsidian-translations/master/translations/<code>.txt` (INI-ish: `[key]` / `original=` / `translation=`).
- Exact-match comparison of short strings flagged ~525 differences across the 3 repos. Mostly synonyms; a few were wrong-sense bugs.
- Obsidian ships `pt` (Portugal) and `pt-BR` separately. The plugin now has both.

## Plugin-specific

- `t()` returns a branded `UIText`; render helpers typed `UIText` reject raw English at tsc.
- The eslint sink rule cannot see a literal passed through a helper. The `UIText` type is what catches it.

## Marketing-specific

- Starlight sidebar `translations` are keyed by lang tag (`pt-BR`), not URL path (`pt-br`).
- starlight-openapi fills its sidebar groups in a route middleware with `order: "post"`, so ours must `await next()` first to edit them.
- Inline `style` attributes violate CSP `style-src 'self'`. Use a class.
