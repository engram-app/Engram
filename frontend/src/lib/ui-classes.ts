import { cn } from "@/lib/utils";

const listRowBase = "relative flex w-full items-center gap-1 rounded pr-3 text-left";
const listRowIdle =
	"text-foreground hover:bg-accent hover:text-accent-foreground data-[highlighted]:bg-accent data-[highlighted]:text-accent-foreground";
const listRowSelected = "bg-row-selected font-medium text-row-selected-foreground";
const listRowMultiSelected = "bg-row-multi-selected text-foreground";

// Single source of truth for repeated Tailwind class patterns across the
// auth / onboarding / consent / settings surfaces. Keep visual changes here.

// Section/page heading used on the branded surfaces.
export const heading = "text-2xl font-bold tracking-tight text-foreground sm:text-3xl";

// Destructive alert box (title + body). Single-line inline errors tighten the
// padding with cn(destructiveAlert, 'p-3 ...').
export const destructiveAlert =
	"rounded-lg border border-destructive/50 bg-destructive/5 p-4 text-sm";

// Selectable bordered row (radio / checkbox card) with active highlight.
// `compact` tightens padding for dense lists (e.g. the onboarding tool picker);
// the default keeps roomy padding for standalone rows (e.g. an agree checkbox).
export function selectableRow(active: boolean, compact = false): string {
	return cn(
		"flex cursor-pointer items-center gap-3 rounded-lg border transition-colors",
		compact ? "p-2.5" : "p-4",
		active ? "border-primary bg-primary/5" : "border-border hover:border-primary/50",
	);
}

// ── List rows ─────────────────────────────────────────────────────────────────
// The file tree and the vault picker are the same kind of list, so everything
// about a row lives here and BOTH call it: shape, layout, hover and selected
// looks, geometry and the inset around the list. Change it here, both follow.
//
// A solid neutral chip, not a tint of the cyan primary -- a tinted highlight
// reads as "blue on blue" against this palette -- and hover owns `accent`, so
// the two states stay distinct. A selected row does NOT take the hover look
// (exclusive, like the tree), so the chip is never overridden. `data-[highlighted]`
// is the hover look for rows a keyboard walks (listbox options); rows that never
// set it ignore it. Colors are the --row-* tokens in main.css.

/** Pinned row height in px. The tree's virtualizer positions rows by it (see
 *  viewer/tree/row-metrics), and the picker's rows must be exactly as tall. */
export const LIST_ROW_HEIGHT = 24;
/** Gap between rows in px. */
export const LIST_ROW_GAP = 2;

/** Classes for one row. Left padding is the caller's (the tree indents by depth). */
export function listRowClass({
	selected = false,
	multiSelected = false,
}: {
	selected?: boolean;
	multiSelected?: boolean;
} = {}): string {
	if (selected) {
		return `${listRowBase} ${listRowSelected}`;
	}
	return `${listRowBase} ${multiSelected ? listRowMultiSelected : listRowIdle}`;
}

/** The inset and text size around a list of rows. 8px keeps the first and last
 *  row off the borders. */
export const listContainer = "p-2 text-base";

/** The "nothing matches" line inside a list. */
export const listEmpty = "px-2 py-6 text-center text-muted-foreground text-xs";
