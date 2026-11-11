import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import {
	type EditorSelection,
	type EditorState,
	Facet,
	type Range,
	RangeSet,
	RangeValue,
	StateField,
	type Transaction,
} from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView } from "@codemirror/view";
import type { SyntaxNode, SyntaxNodeRef, Tree } from "@lezer/common";
import { selectionTouches } from "./decoration-utils";

// The one render core for Rendered mode. Every live-preview layer we own is a
// renderer registered here; none of them decides when to rebuild, walks the
// document or walks the tree. The core does that once, and only over what an
// update actually touched:
//
//   doc change    map tokens + decorations through the change (the interval
//                 shift VS Code's decoration tree does), rescan only from the
//                 last neutral line before the edit to the first neutral line
//                 after it that the old scan agrees on (resync).
//   tree advance  re-render only from the old parse frontier to the new one.
//   selection     re-decorate only tokens under the old and new selection.
//
// It never waits on a full parse (only a bounded initial-viewport one at mount): past the parse frontier the
// old, mapped decorations stay until the tree gets there, like VS Code's
// stale-but-shifted tokens, so nothing flashes unstyled.
//
// One StateField, one output path. Not a viewport ViewPlugin: an incremental
// field already costs nothing on scroll, Atomic measured viewport rebuilds
// halting iOS scroll momentum, and block widgets must live in a field anyway.
// Design: Engram vault "50 Engineering/_Superpowers Specs/2026-11-11-editor-render-pipeline-design.md".

interface Token<T> {
	from: number;
	to: number;
	value: T;
}

/**
 * A resumable line scanner. Tokens are every construct the scan finds, decorated
 * or not (a revealed span, a non-mermaid fence, an unclosed tail), because the
 * core resyncs against them: a line start that no token spans is one where the
 * scan carries no state.
 */
interface TextRenderer<T> {
	kind: "text";
	/**
	 * Scan from `from`, always a line start where the scan is neutral. Emit tokens
	 * in order, non-empty. At every LATER line start where the scan is neutral,
	 * call `neutral(lineStart)` and return if it says true.
	 */
	scan(
		state: EditorState,
		from: number,
		emit: (t: Token<T>) => void,
		neutral: (lineStart: number) => boolean,
	): void;
	/** Decorations for one token. Each must start inside [token.from, token.to). */
	decorate(state: EditorState, token: Token<T>): Range<Decoration>[];
	/** Skip decorating a token the selection touches, so its raw source shows. */
	reveal?: boolean;
	/** Tokens read the syntax tree (code detection), so rescan where it changes. */
	usesTree?: boolean;
	/** Re-decorate every token (no rescan): a facet or effect the widgets read changed. */
	refresh?: (tr: Transaction) => boolean;
}

/** Renders from syntax nodes. All tree renderers share one walk per update. */
interface TreeRenderer {
	kind: "tree";
	/**
	 * A visitor for one walk over [from, to). Ancestors of nodes in the range are
	 * entered too. Emit only decorations that start inside [from, to).
	 */
	visit(
		state: EditorState,
		from: number,
		to: number,
	): {
		enter(node: SyntaxNodeRef): void;
		leave?(node: SyntaxNodeRef): void;
		finish(): Range<Decoration>[];
	};
}

type Renderer = TextRenderer<unknown> | TreeRenderer;

class TokenMark<T> extends RangeValue {
	constructor(readonly value: T) {
		super();
	}
	eq(other: RangeValue): boolean {
		return other instanceof TokenMark && other.value === this.value;
	}
}

interface Layer {
	tokens: RangeSet<TokenMark<unknown>>;
	decos: DecorationSet;
}

interface CoreState {
	layers: Map<Renderer, Layer>;
	/** How far the syntax tree reached when we last rendered from it. */
	treeLen: number;
}

const renderers = Facet.define<Renderer>();

type Span = [from: number, to: number];

function mergeSpans(spans: Span[]): Span[] {
	spans.sort((a, b) => a[0] - b[0]);
	const out: Span[] = [];
	for (const s of spans) {
		const last = out.at(-1);
		if (last && s[0] <= last[1]) {
			last[1] = Math.max(last[1], s[1]);
		} else {
			out.push([s[0], s[1]]);
		}
	}
	return out;
}

/** Does any token span `pos` (start before it, end after it)? */
function spanned(tokens: RangeSet<TokenMark<unknown>>, pos: number): number | null {
	let at: number | null = null;
	tokens.between(pos, pos, (from, to) => {
		if (from < pos && to > pos) {
			at = from;
			return false;
		}
	});
	return at;
}

function decorateTokens(
	state: EditorState,
	r: TextRenderer<unknown>,
	tokens: Iterable<Token<unknown>>,
	out: Range<Decoration>[],
) {
	for (const t of tokens) {
		if (r.reveal && selectionTouches(state.selection, t.from, t.to)) {
			continue;
		}
		out.push(...r.decorate(state, t));
	}
}

function allTokens(set: RangeSet<TokenMark<unknown>>): Token<unknown>[] {
	const out: Token<unknown>[] = [];
	for (const it = set.iter(); it.value; it.next()) {
		out.push({ from: it.from, to: it.to, value: it.value.value });
	}
	return out;
}

/** Drop everything starting in [from, to) and add `add`. */
function patch<T extends RangeValue>(
	set: RangeSet<T>,
	from: number,
	to: number,
	add: Range<T>[],
): RangeSet<T> {
	return set.update({
		filterFrom: from,
		filterTo: to,
		filter: (f) => f < from || f >= to,
		add,
		sort: true,
	});
}

/**
 * Rescan one dirty span for a text renderer. Returns the end of the region it
 * replaced, a line start where the new scan is neutral (or past the doc end).
 */
function rescan(
	state: EditorState,
	r: TextRenderer<unknown>,
	layer: Layer,
	old: RangeSet<TokenMark<unknown>>,
	span: Span,
	floor: number,
): number {
	const { doc } = state;
	// One line of context before the edit (a line can extend the block above it),
	// then back off to the start of any old token that crosses that point.
	let p = doc.lineAt(span[0]).from;
	if (p > 0) {
		p = doc.lineAt(p - 1).from;
	}
	for (let at = spanned(old, p); at !== null; at = spanned(old, p)) {
		p = doc.lineAt(at).from;
	}
	p = Math.max(p, floor);
	const found: Token<unknown>[] = [];
	let end = doc.length + 1;
	r.scan(
		state,
		p,
		(t) => found.push(t),
		(x) => {
			// Past the edit, and the old scan was neutral here too: everything after
			// is the same text scanned from the same state, so the old tokens hold.
			if (x > span[1] && spanned(old, x) === null) {
				end = x;
				return true;
			}
			return false;
		},
	);
	const decos: Range<Decoration>[] = [];
	decorateTokens(state, r, found, decos);
	layer.tokens = patch(
		layer.tokens,
		p,
		end,
		found.map((t) => new TokenMark(t.value).range(t.from, t.to)),
	);
	layer.decos = patch(layer.decos, p, end, decos);
	return end;
}

function renderTree(state: EditorState, tree: Tree, tree$: [TreeRenderer, Layer][], spans: Span[]) {
	for (const [from, to] of spans) {
		if (to <= from) {
			continue;
		}
		const visitors = tree$.map(([r]) => r.visit(state, from, to));
		tree.iterate({
			from,
			to,
			enter: (n) => {
				for (const v of visitors) {
					v.enter(n);
				}
			},
			leave: (n) => {
				for (const v of visitors) {
					v.leave?.(n);
				}
			},
		});
		// A line decoration can sit at the very end (an empty last line).
		const end = to >= state.doc.length ? to + 1 : to;
		tree$.forEach(([, layer], i) => {
			layer.decos = patch(layer.decos, from, end, visitors[i]?.finish() ?? []);
		});
	}
}

/** A node the markdown parser restarts at: a top-level block, or one list item. */
function isUnit(n: SyntaxNode): boolean {
	return n.name === "ListItem" || n.parent?.name === "Document";
}

function unitAt(tree: Tree, pos: number, side: -1 | 1): SyntaxNode | null {
	for (let n: SyntaxNode | null = tree.resolve(pos, side); n; n = n.parent) {
		if (isUnit(n)) {
			return n;
		}
	}
	// Between blocks. The block before can absorb what follows (a lazy line, an
	// indented continuation), so start at its deepest LAST item, not the whole list.
	const nests = (x: SyntaxNode) => /List$|^ListItem$/.test(x.name);
	let n = tree.topNode.childBefore(pos);
	for (let last = n?.lastChild; n && last && nests(n) && nests(last); last = n.lastChild) {
		n = last;
	}
	return n;
}

/**
 * The region an edit of [from, to] can change in the tree: from the unit holding
 * the line before `from` to the start of whatever follows the unit holding `to`.
 * A unit is a top-level block or a list item, because markdown restarts at both,
 * so a list-heavy note (one giant top-level List) re-renders one item, not the list.
 */
function blockRegion(state: EditorState, tree: Tree, from: number, to: number): Span {
	const { doc } = state;
	const q = Math.max(0, doc.lineAt(Math.min(from, doc.length)).from - 1);
	const start = unitAt(tree, q, -1);
	let end: number = tree.length;
	for (let n = unitAt(tree, Math.min(to, tree.length), 1); n; n = n.parent) {
		const next = n.nextSibling;
		if (next) {
			end = next.from;
			break;
		}
		if (n.name === "Document") {
			break;
		}
	}
	return [Math.min(start?.from ?? 0, q), Math.max(end, Math.min(to, tree.length))];
}

function treeSpans(tr: Transaction, startLen: number, tree: Tree): Span[] {
	const { state } = tr;
	const spans: Span[] = [];
	const before = syntaxTree(tr.startState);
	if (tr.docChanged) {
		tr.changes.iterChangedRanges((fromA, toA, fromB, toB) => {
			const [a, b] = blockRegion(tr.startState, before, fromA, toA);
			const [c, d] = blockRegion(state, tree, fromB, toB);
			spans.push([Math.min(tr.changes.mapPos(a, -1), c), Math.max(tr.changes.mapPos(b, 1), d)]);
		});
	}
	// The parser got further than last time: render what it newly covers.
	const frontier = tr.docChanged ? tr.changes.mapPos(startLen, -1) : startLen;
	if (tree.length > frontier) {
		spans.push([blockRegion(tr.state, tree, frontier, frontier)[0], tree.length]);
	}
	// Nothing past the frontier yet: keep the old decorations there.
	return mergeSpans(spans)
		.map(([a, b]): Span => [a, Math.min(b, tree.length)])
		.filter(([a, b]) => b > a);
}

/**
 * How much the mount may parse up front: CodeMirror's own initial-viewport
 * budget. Bounded in size and time, once per mount, never per keystroke; the
 * rest arrives through tree advances.
 */
const MOUNT_PARSE_CHARS = 3000;
const MOUNT_PARSE_MS = 50;

function build(state: EditorState): CoreState {
	const tree =
		ensureSyntaxTree(state, Math.min(state.doc.length, MOUNT_PARSE_CHARS), MOUNT_PARSE_MS) ??
		syntaxTree(state);
	const layers = new Map<Renderer, Layer>();
	const tree$: [TreeRenderer, Layer][] = [];
	for (const r of state.facet(renderers)) {
		const layer: Layer = { tokens: RangeSet.empty, decos: Decoration.none };
		layers.set(r, layer);
		if (r.kind === "text") {
			rescan(state, r, layer, RangeSet.empty, [0, state.doc.length], 0);
		} else {
			tree$.push([r, layer]);
		}
	}
	renderTree(state, tree, tree$, [[0, tree.length]]);
	return { layers, treeLen: tree.length };
}

function selectionSpans(sel: EditorSelection): Span[] {
	return sel.ranges.map((r) => [r.from, r.to]);
}

function update(value: CoreState, tr: Transaction): CoreState {
	const { state } = tr;
	const list = state.facet(renderers);
	if (list !== tr.startState.facet(renderers)) {
		return build(state);
	}
	const tree = syntaxTree(state);
	const treeMoved = tree !== syntaxTree(tr.startState);
	if (!(tr.docChanged || treeMoved || tr.selection || tr.effects.length > 0)) {
		return value;
	}
	const edits: Span[] = [];
	tr.changes.iterChangedRanges((_fa, _ta, fromB, toB) => {
		edits.push([fromB, toB]);
	});
	const tSpans = treeMoved ? treeSpans(tr, value.treeLen, tree) : [];
	const oldSel = tr.startState.selection.map(tr.changes);
	const layers = new Map<Renderer, Layer>();
	const tree$: [TreeRenderer, Layer][] = [];
	for (const r of list) {
		const prev = value.layers.get(r);
		if (!prev) {
			return build(state);
		}
		const old = tr.docChanged ? prev.tokens.map(tr.changes) : prev.tokens;
		const layer: Layer = {
			tokens: old,
			decos: tr.docChanged ? prev.decos.map(tr.changes) : prev.decos,
		};
		layers.set(r, layer);
		if (r.kind === "tree") {
			tree$.push([r, layer]);
			continue;
		}
		if (r.refresh?.(tr)) {
			const decos: Range<Decoration>[] = [];
			decorateTokens(state, r, allTokens(old), decos);
			layer.decos = Decoration.set(decos, true);
		}
		let floor = 0;
		for (const span of mergeSpans([...edits, ...(r.usesTree ? tSpans : [])])) {
			if (span[1] < floor) {
				continue;
			}
			floor = rescan(state, r, layer, old, span, floor);
		}
		if (r.reveal && (tr.selection || tr.docChanged)) {
			revealPatch(state, r, layer, [...selectionSpans(oldSel), ...selectionSpans(state.selection)]);
		}
	}
	renderTree(state, tree, tree$, tSpans);
	return { layers, treeLen: tree.length };
}

/** Re-decorate the tokens under the old and new selection, and nothing else. */
function revealPatch(state: EditorState, r: TextRenderer<unknown>, layer: Layer, spans: Span[]) {
	const hit = new Map<number, Token<unknown>>();
	for (const [from, to] of spans) {
		layer.tokens.between(from, to, (f, t, v) => {
			hit.set(f, { from: f, to: t, value: v.value });
		});
	}
	for (const t of hit.values()) {
		const decos: Range<Decoration>[] = [];
		decorateTokens(state, r, [t], decos);
		layer.decos = patch(layer.decos, t.from, t.to, decos);
	}
}

const renderCore = StateField.define<CoreState>({ create: build, update });

/** Tokens of a text renderer touching [from, to]. O(log n + k). */
function tokensAt(
	state: EditorState,
	r: TextRenderer<unknown>,
	from: number,
	to: number,
): Token<unknown>[] {
	const out: Token<unknown>[] = [];
	state
		.field(renderCore, false)
		?.layers.get(r)
		?.tokens.between(from, to, (f, t, v) => {
			out.push({ from: f, to: t, value: v.value });
		});
	return out;
}

/**
 * Register a renderer. The returned field holds its decorations (so callers and
 * tests can read them) and brings the core with it; wrap it in Prec at the use
 * site to set its precedence.
 */
function defineRenderer(r: Renderer): StateField<DecorationSet> {
	const pick = (s: EditorState) => s.field(renderCore).layers.get(r)?.decos ?? Decoration.none;
	return StateField.define<DecorationSet>({
		create: pick,
		update: (_v, tr) => pick(tr.state),
		provide: (f) => [renderCore, renderers.of(r), EditorView.decorations.from(f)],
	});
}

export type { Renderer, TextRenderer, Token, TreeRenderer };
export { defineRenderer, tokensAt };
