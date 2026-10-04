import { LIST_ROW_GAP, LIST_ROW_HEIGHT } from "../../lib/ui-classes";

// Row height and gap are shared with the vault picker, so their values live in
// lib/ui-classes; these are the tree's names for them.
// One source of truth for tree row geometry.
//
// The virtualizer positions every row at `index * TREE_SLOT_HEIGHT` and does
// NOT measure them. Measuring (`virtualizer.measureElement`) is the obvious
// alternative and it is correct, but it costs a synchronous layout per row:
// expanding one folder mounts a screenful at once and a trace showed 60ms of
// forced reflow inside `measureElement`, which janked the chevron animation.
//
// So the row height is PINNED to match the slot rather than guessed at. These
// two must agree — that they used to disagree (24px slots holding 28px rows) is
// what made hover fills overlap.
//
// ponytail: pinned, so a row can't grow to fit its content. If the tree's
// font-size changes, TREE_ROW_HEIGHT changes with it or the text clips. Switch
// to `measureElement` only if rows ever need to be genuinely variable-height —
// and re-measure the expand interaction if you do.
export const TREE_ROW_HEIGHT = LIST_ROW_HEIGHT;
export const TREE_ROW_GAP = LIST_ROW_GAP;
export const TREE_SLOT_HEIGHT = TREE_ROW_HEIGHT + TREE_ROW_GAP;
