import { type EditorSelection, type Range, RangeSetBuilder } from "@codemirror/state";
import type { Decoration, DecorationSet } from "@codemirror/view";

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

/**
 * Drain collected ranges into a DecorationSet.
 *
 * RangeSetBuilder only accepts ranges in ascending `from` order and throws
 * otherwise, so callers that discover ranges out of order (regex scans) must
 * sort first. The sort is stable, which matters where several decorations share
 * a `from` and their relative order is deliberate.
 *
 * Note: callout-decoration.ts deliberately does NOT use this. It adds line and
 * replace decorations at the same offset in an order chosen for startSide, and
 * routing that through a sort would obscure a constraint it documents inline.
 */
export function decorationSet(ranges: readonly Range<Decoration>[]): DecorationSet {
	const builder = new RangeSetBuilder<Decoration>();
	for (const r of [...ranges].sort((a, b) => a.from - b.from)) {
		builder.add(r.from, r.to, r.value);
	}
	return builder.finish();
}
