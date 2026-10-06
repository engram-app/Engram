# Form controls: one height, one component

Single-line controls share ONE height token: `--spacing-control` (2.375rem, 38px)
in `frontend/src/main.css`, used as `h-control` / `size-control`.

- `<Button>` default size and `icon` size, `<Input>`, and the `<SelectTrigger>`
  default all use it. Put a default-size `<Button>` next to an `<Input>` or select
  and the heights match; never hand-pick `h-8`/`h-9`/`h-10` for them.
- Compact buttons are `size="sm"` / `"xs"` (and `icon-sm` / `icon-xs`). Use them
  in table rows, toolbars and badges, NOT in the same row as an input.
- Boxed text fields use `<Input>` from `@/components/ui/input`. Do not hand-roll
  `border-input` on a raw `<input>`, and do not add a `fieldInput`-style class
  string. Layout (`mt-1 block`, `flex-1`, `shrink-0`) goes in `className`.
- Raw `<input>` is fine for checkboxes, radios, `type="file"`, hidden inputs,
  chromeless inline-edit cells (rename input, property cells) and editor surfaces.
- `<Input>` is `text-base md:text-sm` on purpose: 16px on mobile stops iOS zoom.

Guard: `frontend/src/lib/control-height.test.ts` fails if `fieldInput` returns to
`lib/ui-classes.ts` or a raw `<input>` outside `components/ui` carries `border-input`.
