# Form controls: one height, one component

Single-line controls share ONE height token: `--spacing-control` (2.375rem, 38px)
in `frontend/src/main.css`, used as `h-control` / `size-control`.

- `<Button>` default size and `icon` size, `<Input>`, and the `<SelectTrigger>`
  default all use it. Put a default-size `<Button>` next to an `<Input>` or select
  and the heights match; never hand-pick `h-8`/`h-9`/`h-10` for them.
- Compact buttons are `size="sm"` (and `icon-sm`). Use them in table rows, list
  rows, banners and toolbars, NOT in the same row as an input.
- Boxed text fields use `<Input>` from `@/components/ui/input`. Do not hand-roll
  `border-input` on a raw `<input>`, and do not add a `fieldInput`-style class
  string. Layout (`mt-1 block`, `flex-1`, `shrink-0`) goes in `className`.
- Raw `<input>` is fine for checkboxes, radios, `type="file"`, hidden inputs,
  chromeless inline-edit cells (rename input, property cells) and editor surfaces.
- `<Input>` is `text-base md:text-sm` on purpose: 16px on mobile stops iOS zoom.

Guard: `frontend/src/lib/control-height.test.ts` fails if `fieldInput` returns to
`lib/ui-classes.ts` or a raw `<input>` outside `components/ui` carries `border-input`.

## Buttons

Every standard button is the shared `<Button>` (`components/ui/button.tsx`). One
role, one variant, one size. Do not add a button class constant to
`lib/ui-classes.ts` (`ctaFilled`/`ctaOutline` are gone).

| Role | Variant |
|------|---------|
| The single main action of a card, dialog, form or page (Save, Create, Continue, Upgrade, Confirm, Sign in) | `default` |
| Secondary action (Cancel, Back, Change password, Manage, Copy, Edit, Reload, Back to home) | `outline` |
| Any destructive action, including the final confirm inside a delete dialog and a row's Revoke/Disconnect | `destructive` |
| Tertiary, in-row and toolbar actions, icon buttons, close buttons | `ghost` |
| Inline text action inside prose | `link` |

There is no `secondary` variant and no `xs` size; map to `outline` / `sm`.

Sizes: `default` (38px) for every standalone, form, card and dialog-footer button.
`sm` only for compact actions in a table row, list row, banner or toolbar. `icon`
for icon-only buttons (`icon-sm` in a dense row). `lg` / `icon-lg` (44px) only for
touch targets: the mobile top-bar triggers and the floating checklist button.
`icon-xs` exists for the combobox clear/trigger inside `components/ui`.

className on a `<Button>` is layout only: width, margin, `shrink-0`, `self-*`,
`justify-*`, gap, positioning. Never a color, background, border, radius, height or
ring; pick the variant instead. A link that looks like a button is
`<Button asChild><Link|a>...</Link|a></Button>`.

Icons: put the icon inside the `<Button>` and mark it `data-icon="inline-start"` or
`"inline-end"`. The Button sizes the svg and trims the padding on that side, so no
`mr-*` or `size-*` on the icon. Icon-only: `size="icon"`, an `aria-label`, and a
tooltip/`title` when the meaning is not obvious.

Stays a raw `<button>` when it is not a standard button: tabs, tree/list/menu rows,
toggles, chips, selectable cards, overlays/backdrops, click-to-rename text, and the
forced-light Paddle checkout card. Those files are listed, with a reason, in
`RAW_BUTTON_ALLOWLIST` in `frontend/src/lib/button-style.test.ts`.

Guard: `frontend/src/lib/button-style.test.ts` fails if `ctaFilled`/`ctaOutline`
return, a `<Button>` uses a variant outside the five above or a className with a
color/background/border/radius/height/ring utility, or a raw `<button>` outside the
allow-list hand-rolls a solid or boxed look. Allow-list entries must still contain
a raw `<button>`.
