import { type EditorState, Prec, type Range, StateField, type Text } from "@codemirror/state";
import {
	type Command,
	Decoration,
	type DecorationSet,
	EditorView,
	keymap,
	WidgetType,
} from "@codemirror/view";
import { nextMermaidId, renderMermaid } from "../mermaid-render";
import { selectionTouches } from "./decoration-utils";
import "./mermaid.css";

/**
 * Renders one mermaid fence. The SVG arrives asynchronously, so toDOM returns an
 * empty container immediately and fills it later.
 */
class MermaidWidget extends WidgetType {
	constructor(
		private readonly code: string,
		private readonly dark: boolean,
	) {
		super();
	}

	// Includes `dark`: the palette is baked into the SVG rather than applied as
	// CSS, so a theme flip has to produce a NEW widget or the diagram keeps the
	// old colours. buildMermaid reads the theme, which is what makes this differ.
	eq(other: MermaidWidget) {
		return other.code === this.code && other.dark === this.dark;
	}

	toDOM(view: EditorView) {
		const el = document.createElement("div");
		el.className = "cm-mermaid-widget";
		// CM6 measured this widget's height while it was still empty. Once the SVG
		// lands the box grows, and without a re-measure the heightmap keeps the old
		// height — every line below the diagram then maps to the wrong screen
		// position, which shows up as clicks landing on the neighbouring line.
		const measure = () => view.requestMeasure();
		renderMermaid(nextMermaidId(), this.code, this.dark)
			.then((svg) => {
				el.innerHTML = svg;
				measure();
			})
			.catch((err: unknown) => {
				// Show the diagram's own error rather than an empty box, and keep the
				// source visible so it can be fixed. Mermaid rejects on any syntax
				// slip, which is a normal state while typing.
				el.classList.add("cm-mermaid-error");
				el.textContent = `Mermaid error: ${err instanceof Error ? err.message : String(err)}`;
				measure();
			});
		return el;
	}

	// The widget is inert content, not a control; let clicks through so the caret
	// can be placed and the raw source revealed.
	ignoreEvent() {
		return false;
	}
}

// Read at build time, not inside the widget, so `eq` can see it change. The app
// puts `.dark` on <html> (see theme/resolve.ts).
//
// ponytail: sampling the DOM rather than subscribing to the theme store. The
// field rebuilds on any doc or selection change, so a theme flip repaints on the
// next keystroke or cursor move rather than instantly. If that lag ever grates,
// dispatch a StateEffect from ThemeProvider and rebuild on it.
function isDark(): boolean {
	return document.documentElement.classList.contains("dark");
}

interface Fence {
	/** Document offsets of the whole block, opening fence through closing fence. */
	from: number;
	to: number;
	openLine: number;
	closeLine: number;
	code: string;
}

// CommonMark fences, not just ```mermaid at column 0. The run of backticks and
// the indentation are captured because both are load-bearing: a closing fence
// must be at LEAST as long as its opener, which is the whole mechanism by which
// a ````markdown block can quote a ```mermaid one.
//
// Info strings cannot contain a backtick, which is what keeps FENCE_OPEN from
// matching a closer.
const FENCE_OPEN = /^(?<indent> {0,3})(?<ticks>`{3,})[ \t]*(?<info>[^`]*?)[ \t]*$/;
const FENCE_CLOSE = /^ {0,3}(?<ticks>`{3,})[ \t]*$/;

/**
 * Every complete ```mermaid block in the document.
 *
 * Walks EVERY fence, not just the mermaid ones, and jumps the scan past each
 * one it finds. That is what stops a ```mermaid line QUOTED inside a wider
 * documentation fence from being read as a real block — it is content, and the
 * scanner never looks at it. Leading indentation up to three spaces is allowed,
 * so a fence inside a list item renders here as it already did in Reading mode.
 *
 * Scanned rather than read off syntaxTree(state), which was tried and reverted.
 * The tree is parsed LAZILY: on a fresh EditorState it covered seven characters,
 * and in a real editor it trails the viewport on a long note. Fences below the
 * parse frontier would simply stop rendering — a worse failure than the two
 * cases the tree would have fixed. This scan is O(lines) and always complete.
 *
 * ponytail: three spaces is the CommonMark document-level allowance, so a fence
 * indented further by a NESTED list item is still missed. Upgrade path is to
 * track container indentation; not worth it until someone hits it.
 *
 * Shared by the decoration and the arrow-key commands on purpose: two scanners
 * would be two answers to "where does this block start", and the commands exist
 * precisely to land the caret on a boundary the decoration computed.
 */
function fenceRanges(doc: Text): Fence[] {
	const out: Fence[] = [];
	let lineNo = 1;
	while (lineNo <= doc.lines) {
		const line = doc.line(lineNo);
		const open = FENCE_OPEN.exec(line.text);
		if (!open) {
			lineNo++;
			continue;
		}
		const indent = open.groups?.indent?.length ?? 0;
		const ticks = open.groups?.ticks?.length ?? 0;
		const info = open.groups?.info ?? "";

		let closeNo = 0;
		for (let n = lineNo + 1; n <= doc.lines; n++) {
			const close = FENCE_CLOSE.exec(doc.line(n).text);
			if (close && (close.groups?.ticks?.length ?? 0) >= ticks) {
				closeNo = n;
				break;
			}
		}
		// No closer means the block is still being typed — and that everything
		// below is inside it, so there is nothing further to find either.
		if (closeNo === 0) {
			break;
		}

		if (info === "mermaid") {
			const body: string[] = [];
			for (let n = lineNo + 1; n < closeNo; n++) {
				body.push(dedent(doc.line(n).text, indent));
			}
			out.push({
				from: line.from,
				to: doc.line(closeNo).to,
				openLine: lineNo,
				closeLine: closeNo,
				code: body.join("\n"),
			});
		}
		// Past the whole block whether or not it was ours: everything between the
		// marks is content, including any line that looks like a fence.
		lineNo = closeNo + 1;
	}
	return out;
}

/** Drop up to `width` leading spaces, so an indented diagram reaches mermaid flush. */
function dedent(line: string, width: number): string {
	let i = 0;
	while (i < width && line[i] === " ") {
		i++;
	}
	return line.slice(i);
}

function buildMermaid(state: EditorState): DecorationSet {
	const { doc, selection: sel } = state;
	const dark = isDark();
	const ranges: Range<Decoration>[] = [];

	for (const fence of fenceRanges(doc)) {
		// Reveal raw when the cursor/selection intersects the block, matching
		// callouts and math.
		if (selectionTouches(sel, fence.from, fence.to)) {
			continue;
		}
		ranges.push(
			Decoration.replace({
				widget: new MermaidWidget(fence.code, dark),
				block: true,
			}).range(fence.from, fence.to),
		);
	}

	// `true` = let RangeSet sort. The scan is in document order, but the cost is
	// nil and an unsorted set throws.
	return Decoration.set(ranges, true);
}

/**
 * Vertical motion into a rendered block.
 *
 * A block replace leaves no visible position inside it, so CM6's ArrowDown/Up
 * step over the entire diagram: measured in a real editor, ArrowDown from the
 * line above a fence landed on the line BELOW the closing fence. The block was
 * unreachable by keyboard, openable only by clicking it. Callouts never had the
 * problem because only their header LINE is replaced, leaving the body lines
 * navigable.
 *
 * Landing the caret ON the fence reveals the source (the decoration skips any
 * block the selection intersects), so from there normal motion walks the
 * diagram and leaving it re-renders — the same feel as arrowing into a callout.
 */
function enterFence(view: EditorView, forward: boolean): boolean {
	const { state } = view;
	const range = state.selection.main;
	// Shift+Arrow is selecting, not navigating; hijacking it would collapse the
	// selection the user is building.
	if (!range.empty) {
		return false;
	}
	const { doc } = state;
	const caretLine = doc.lineAt(range.head).number;
	// Vertical motion is VISUAL, not per-line: a soft-wrapped paragraph above a
	// fence occupies several screen rows, and a line-number check alone fired on
	// every one of them — ArrowDown from the paragraph's first row teleported into
	// the diagram, skipping the rest of the text the user was reading. Ask CM6
	// where the caret would actually land instead. Landing on a different line
	// means this really is the last (or first) visual row of it.
	//
	// `moved === range.head` covers the no-layout case (jsdom, an unmeasured
	// view), where moveVertically cannot move and would otherwise disable the
	// keymap outright.
	const moved = view.moveVertically(range, forward).head;
	if (moved !== range.head && doc.lineAt(moved).number === caretLine) {
		return false;
	}
	for (const fence of fenceRanges(doc)) {
		// Already inside: the block is revealed and normal motion is what should
		// carry the caret through its lines.
		if (range.head >= fence.from && range.head <= fence.to) {
			return false;
		}
		// Enter at the near edge, so continuing in the same direction reads the
		// source in the order you were already travelling.
		const entering = forward ? caretLine === fence.openLine - 1 : caretLine === fence.closeLine + 1;
		if (entering) {
			view.dispatch({
				selection: { anchor: forward ? fence.from : fence.to },
				scrollIntoView: true,
			});
			return true;
		}
	}
	return false;
}

export const enterMermaidDown: Command = (view) => enterFence(view, true);
export const enterMermaidUp: Command = (view) => enterFence(view, false);

// Prec.highest so this runs before the default cursor-motion bindings, which
// would otherwise consume the key and skip the block.
export const mermaidKeymap = Prec.highest(
	keymap.of([
		{ key: "ArrowDown", run: enterMermaidDown },
		{ key: "ArrowUp", run: enterMermaidUp },
	]),
);

/**
 * Renders ```mermaid fences in the editor, the way Reading mode already does.
 *
 * StateField, not ViewPlugin: a mermaid fence is always multi-line, so its
 * replace decoration spans line breaks, and CM6 only accepts those from the
 * decorations facet fed by a state field. See katex-decoration.ts, which hit the
 * same rule.
 *
 * View-only. It decorates the markdown source and never mutates
 * EditorState.doc, leaving the yCollab Y.Text binding untouched.
 */
export const mermaidDecoration = StateField.define<DecorationSet>({
	create: (state) => buildMermaid(state),
	update(value, tr) {
		if (tr.docChanged || tr.selection) {
			return buildMermaid(tr.state);
		}
		return value;
	},
	provide: (f) => EditorView.decorations.from(f),
});
