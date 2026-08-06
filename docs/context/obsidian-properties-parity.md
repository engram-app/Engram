# Reading Obsidian's real CSS, and the Properties geometry we copied

Done 2026-08-02 to make the web app's frontmatter block look like Obsidian's
Properties. The useful half of this doc is the extraction recipe — the docs
site lists the CSS variable *names* but none of their values, and blog posts
mostly quote people's custom snippets rather than the defaults.

## Getting the authoritative CSS

`docs.obsidian.md` is an Obsidian Publish site rendered client-side, so
scraping it yields an empty shell. The developer-docs markdown on GitHub has
the variable names but, again, no values.

The real file is `app.css` inside the app bundle:

```bash
# The AppImage lives at ~/Applications/Obsidian.AppImage on this machine.
cd /tmp/scratch
~/Applications/Obsidian.AppImage --appimage-extract resources/obsidian.asar
bunx --bun @electron/asar extract-file squashfs-root/resources/obsidian.asar app.css
```

That drops a ~600KB `app.css`. From there:

```bash
grep -o -- '--metadata-[a-z-]*:[^;]*;' app.css | sort -u   # every default value
grep -n '^\.metadata-' app.css                             # rule line numbers
```

Note `grep`ping the `.asar` directly finds the *JavaScript* copies of those
class names, not the stylesheet — extract `app.css` properly or you will read
bundled JS and conclude the rules do not exist.

## The Properties geometry (Obsidian defaults)

| What | Obsidian | Ours |
|---|---|---|
| container padding | `--metadata-padding: 8px 0` | `py-2` |
| gap down to the body | `margin-block-end: 2rem` | `mb-8` |
| container background / border | transparent, `border-width: 0` | none |
| gap between rows | `--metadata-gap: 3px` | `gap-[3px]` |
| row radius | `--metadata-property-radius: 6px` | `rounded-md` |
| row layout | `display: flex; align-items: start` | same |
| key column width | `--metadata-label-width: 9em` → 144px, `flex-shrink: 0` | `w-36 min-w-36 shrink-0` |
| key font size | `--font-smaller: 0.875em` → 14px | `text-sm` |
| key colour | `--text-muted` | `text-muted-foreground` |
| cell padding | `--metadata-input-padding: 4px 8px` | `px-2 py-1` |
| row height | `--metadata-input-height: calc(16px * 1.75)` → 28px | `min-h-7` |
| value cell | `flex: 1 1 auto; gap: 4px` | `flex-1 gap-1` |
| value inputs | `background: transparent; border-width: 0` | same |

## The surprising part: the default has no hover or focus feedback

Every one of these resolves to `transparent`:

- `--metadata-property-background` / `-hover`
- `--metadata-label-background` / `-hover`
- `--metadata-input-background` / `-hover`
- `--metadata-divider-width: 0` (so no rules between properties either)

The only non-transparent states are `--metadata-label-background-active` and
`--metadata-input-background-active` (both `--background-modifier-hover`), and
`.metadata-property-value .metadata-input-text:focus` explicitly forces the
value back to transparent. So focusing a *value* tints nothing at all — the
caret is the entire affordance.

This is why so many community CSS snippets exist for "properties on hover":
the stock look is deliberately bare. We replicated it as-is. If it reads as
too flat for the web app, the one-line change is a `hover:bg-muted` on the row
in `properties-widget.tsx` — that is what the popular snippets do.

## Where we deliberately diverge

- **Row actions.** Obsidian puts move/remove in a right-click menu and shows
  nothing in the row. We keep the `^ v x` buttons but reveal them on
  hover/focus, so the resting state matches without losing the capability.
- **Key text is not editable.** Obsidian's key is an `input`
  (`.metadata-property-key-input`) you can retype to rename the property. Ours
  is a `<span>`. Renaming a key was out of scope.
- **Semantics.** Obsidian uses divs throughout; we keep `dl`/`dt`/`dd`, with
  each row a `div` wrapping its `dt`+`dd` (valid since HTML 5.2) so the row
  still has a box to carry radius and hover state.
