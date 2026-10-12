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
