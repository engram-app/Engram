# Web app (frontend/) - UI rules

These are the owner's standing design rules, collected from repeated review feedback. Check every screen against them BEFORE showing it. A screen that breaks one goes back for another pass.

## Layout
- **The page body never scrolls in onboarding, modals or consent screens.** Size every section to the viewport, minus the app header. Long lists get their own scroll area.
- Use shadcn primitives (`ScrollArea`, `Dialog`, `Button`, ...) and the existing tokens. Don't hand-roll a control the design system already has. Match the existing style before inventing a new one.
- One-row headers. Don't add a second header row; fold the controls into the existing one. A search icon turns into the input in the same spot.
- Align controls across rows. Leave padding between a scrollbar and the controls next to it.
- Side-by-side cards sit on the same z-index, so one card's shadow never falls on its neighbour.
- Mobile: actions go in a full-width bottom row. Hide secondary details behind "View details" rather than cramming rows.

## Content
- **Less text.** Cut copy that repeats, or that the user already knows ("You will return to X" said twice). The one line that matters must be the most prominent.
- Design for variable-length strings: long email addresses, file names and vault names must wrap or truncate cleanly, never break the layout.
- Label every checkbox on its own row ("Read [ ]  Write [ ]"), not once in a header. Checking Write implies Read.
- Pinned or special rows (for example "Vaults you create later") come first and look slightly different, so they aren't lost in a long list.
- Upgrade nudges are soft ("Get more with paid") and appear once per screen, never twice.

## Modals and errors
- A modal has a real title (heading), body text at normal reading size, and a primary button that does the useful thing (for example **Upgrade**, which opens the settings upgrade page), not a bare "OK".
- **Block an invalid action before the flow starts.** State limits up front ("Max file size is X. Upgrade for Y"); don't let the user pick a file and a location and only then refuse.
- Destructive buttons are red.
- No low-effort modals: if it looks like a browser `alert()`, redo it.

## Behaviour
- Optimistic updates for renames and moves: the UI changes immediately and rolls back on error.
- One component per pattern, reused across flows. Vault access picking, for example, is the same component in OAuth consent, API key creation and connection editing. Never copy-paste a variant.
- Animations are purposeful: nothing animates without a reason, and nothing "pops".

## Before you hand it over
- Check desktop AND mobile widths.
- Drive the flow in the browser yourself, then tell the owner exactly what to click.
