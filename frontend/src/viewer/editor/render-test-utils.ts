import { ensureSyntaxTree } from "@codemirror/language";
import { EditorState, type Extension, type StateField } from "@codemirror/state";
import type { Decoration, DecorationSet } from "@codemirror/view";

// Test helpers for the render core: the incremental result must equal a fresh
// build of the same document, and an edit must not rebuild what it did not touch.

export type Placed = [from: number, to: number, deco: Decoration];

export function placed(set: DecorationSet): Placed[] {
	const out: Placed[] = [];
	set.between(0, Number.MAX_SAFE_INTEGER, (from, to, deco) => {
		out.push([from, to, deco]);
	});
	return out;
}

/** Decorations of `field` in a state built from scratch with the same doc and selection. */
export function fresh(
	state: EditorState,
	extensions: Extension,
	field: StateField<DecorationSet>,
): Placed[] {
	// The incremental side has had every chance to parse; give the fresh one the same.
	const s = settle(EditorState.create({ doc: state.doc, selection: state.selection, extensions }));
	return placed(s.field(field));
}

/**
 * Where the incremental decorations differ from a fresh build's: ranges that
 * differ, or `eq` failing at the same range. Empty means identical.
 */
export function diffFromFresh(
	state: EditorState,
	extensions: Extension,
	field: StateField<DecorationSet>,
): string[] {
	const got = placed(state.field(field));
	const want = fresh(state, extensions, field);
	const out: string[] = [];
	for (let i = 0; i < Math.max(got.length, want.length); i++) {
		const g = got[i];
		const w = want[i];
		if (!(g && w && g[0] === w[0] && g[1] === w[1] && g[2].eq(w[2]))) {
			out.push(
				`#${i}: got ${g ? `${g[0]}-${g[1]}` : "none"}, want ${w ? `${w[0]}-${w[1]}` : "none"}`,
			);
		}
	}
	return out;
}

/** A state whose tree covers the whole doc, so tests do not depend on parse timing. */
export function parsedState(doc: string, extensions: Extension, anchor = 0): EditorState {
	const s = EditorState.create({ doc, extensions, selection: { anchor } });
	return settle(s);
}

/** Finish the parse and let the fields see it, as the view's parse worker would. */
export function settle(s: EditorState): EditorState {
	ensureSyntaxTree(s, s.doc.length, 5000);
	return s.update({}).state;
}
