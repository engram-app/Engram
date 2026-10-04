import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { type EditorState, type Range, StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView } from "@codemirror/view";

// Indent guides for nested lists, the same idea as the file tree's: one thin
// vertical rail per level above the line's own. The rails are drawn by CSS
// (obsidian-theme.css, `.cm-list-rails`) from a per-line `--rails` count, and sit
// at the same `--engram-indent` the Tab key moves by, so they line up with the
// indentation. View-only: line attributes, never a document change.
//
// A line's depth is how many ListItems contain it, so wrapped text and continuation
// paragraphs of an item carry their item's rails too.
/** One Tab / one list level. Obsidian calls its tab "4 spaces" but draws list indents 2em wide (its --list-indent), which is what it looks like next to 4 space-widths of this font (~1.1em). */
const INDENT = "2em";

/** Atomic's list geometry (inline-preview.js LIST_BASE_EM / LIST_ALCOVE_EM), which this extends. */
const ATOMIC_LIST_BASE_EM = 0.8;
const ATOMIC_LIST_ALCOVE_EM = 1.2;

/**
 * Where a rail sits inside Atomic's marker alcove, from the list's left edge. A
 * bullet is a 1.2em box with the dot at its right, so the dot's centre is ~0.6em in;
 * a number is a narrower 0.9em box with the numeral at its left, so its rail sits
 * ~0.35em in. Measured against the rendered markers, not derived.
 */
const RAIL_OFFSET_EM: Record<string, number> = { BulletList: 0.6, OrderedList: 0.35 };

interface LineInfo {
	depth: number;
	/** List kind of each ancestor item above the line's own, outermost first. */
	kinds: string[];
}

function build(state: EditorState): DecorationSet {
	const byLine = new Map<number, LineInfo>();
	const stack: string[] = [];
	// Bounded full parse: the tree is otherwise lazy and trails the viewport.
	ensureSyntaxTree(state, state.doc.length, 100)?.iterate({
		enter: (node) => {
			if (node.name !== "ListItem") {
				return;
			}
			stack.push(node.node.parent?.name ?? "BulletList");
			const depth = stack.length;
			const kinds = stack.slice(0, -1);
			const last = state.doc.lineAt(node.to).number;
			for (let n = state.doc.lineAt(node.from).number; n <= last; n++) {
				if (depth > (byLine.get(n)?.depth ?? 0)) {
					byLine.set(n, { depth, kinds });
				}
			}
		},
		leave: (node) => {
			if (node.name === "ListItem") {
				stack.pop();
			}
		},
	});
	const out: Range<Decoration>[] = [];
	for (const [n, { depth, kinds }] of byLine) {
		if (depth < 2) {
			continue;
		}
		// One 1px layer per ancestor level, each placed under that ancestor's marker.
		const xs = kinds.map((kind, k) => {
			const offset = RAIL_OFFSET_EM[kind] ?? 0.6;
			return `calc(${ATOMIC_LIST_BASE_EM + offset}em + ${k} * ${INDENT}) 0`;
		});
		const layers = xs.map(() => "linear-gradient(var(--border), var(--border))").join(",");
		out.push(
			Decoration.line({
				class: "cm-list-rails",
				// Atomic indents a nested item by a fixed 0.6em per level whatever the Tab
				// size is (it replaces the leading whitespace with nothing and sets
				// padding-left itself: base 0.8em + alcove 1.2em + depth * 0.6em). Set the
				// same padding with OUR level size so nested lists respect the indent.
				attributes: {
					style: `--rails:${depth - 1};padding-left:calc(${ATOMIC_LIST_BASE_EM + ATOMIC_LIST_ALCOVE_EM}em + ${depth - 1} * ${INDENT});background-image:${layers};background-repeat:no-repeat;background-size:${xs.map(() => "1px 100%").join(",")};background-position:${xs.join(",")}`,
				},
			}).range(state.doc.line(n).from),
		);
	}
	return Decoration.set(out, true);
}

export const listRails = [
	StateField.define<DecorationSet>({
		create: build,
		// The tree can change without the document (it parses in the background), so
		// rebuild when the tree identity moves too.
		update: (deco, tr) =>
			tr.docChanged || syntaxTree(tr.state) !== syntaxTree(tr.startState) ? build(tr.state) : deco,
		provide: (f) => EditorView.decorations.from(f),
	}),
	// One indent size for both the Tab character and the rails: change INDENT here
	// and both follow. A length, not a number of spaces: CodeMirror's own tab-size
	// is in space widths, which in this proportional font is barely over 1em.
	EditorView.contentAttributes.of({ style: `--engram-indent: ${INDENT}; tab-size: ${INDENT}` }),
];
