import { ensureSyntaxTree } from "@codemirror/language";
import { EditorState, type Extension, type StateField } from "@codemirror/state";
import type { Decoration, DecorationSet } from "@codemirror/view";
import { vi } from "vitest";
import type { TextRenderer, TreeRenderer } from "./render-core";

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

/**
 * Characters a renderer was asked to cover while `run` executes: the visited
 * spans of a tree renderer, the scanned stretch of a text renderer. The proof
 * that an edit costs the edit, not the note.
 */
export function workDuring(r: TreeRenderer | TextRenderer<unknown>, run: () => void): number {
	let chars = 0;
	if (r.kind === "tree") {
		const original = r.visit.bind(r);
		const spy = vi.spyOn(r, "visit").mockImplementation((state, from, to) => {
			chars += to - from;
			return original(state, from, to);
		});
		try {
			run();
		} finally {
			spy.mockRestore();
		}
		return chars;
	}
	const original = r.scan.bind(r);
	const spy = vi.spyOn(r, "scan").mockImplementation((state, from, emit, neutral, tree) => {
		let reached = from;
		original(
			state,
			from,
			(t) => {
				reached = Math.max(reached, t.to);
				emit(t);
			},
			(x) => {
				reached = Math.max(reached, x);
				return neutral(x);
			},
			tree,
		);
		chars += reached - from;
	});
	try {
		run();
	} finally {
		spy.mockRestore();
	}
	return chars;
}
