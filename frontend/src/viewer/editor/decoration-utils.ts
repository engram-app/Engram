import type { EditorSelection } from "@codemirror/state";

/**
 * Does the caret or selection touch `[from, to]`?
 *
 * This is the "reveal raw source" test every live-preview decoration shares:
 * callouts, block math and mermaid all render a widget UNLESS the selection is
 * inside, so you can always edit what you are standing on. Inclusive at both
 * ends on purpose — a caret resting on the closing delimiter is still in the
 * block, and getting that boundary wrong strands the caret in a region it
 * cannot see.
 *
 * Shared rather than re-typed per extension: three copies of one predicate is
 * three chances for the boundary to drift apart.
 */
export function selectionTouches(sel: EditorSelection, from: number, to: number): boolean {
	return sel.ranges.some((r) => r.from <= to && r.to >= from);
}
