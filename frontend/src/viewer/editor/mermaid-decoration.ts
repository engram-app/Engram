import {
	type EditorState,
	Prec,
	type Range,
	RangeSetBuilder,
	StateField,
	type Text,
} from "@codemirror/state";
import {
	type Command,
	Decoration,
	type DecorationSet,
	EditorView,
	keymap,
	WidgetType,
} from "@codemirror/view";
import { nextMermaidId, renderMermaid } from "../mermaid-render";
import "./mermaid.css";

// ```mermaid opens; any bare ``` closes. Info strings other than "mermaid" are
// somebody else's fence (and `codeLanguages` in live-preview.ts highlights those).
const FENCE_OPEN = /^```mermaid\s*$/;
const FENCE_CLOSE = /^```\s*$/;

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
}

/**
 * Every complete ```mermaid block in the document.
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
		if (!FENCE_OPEN.test(line.text)) {
			lineNo++;
			continue;
		}
		// Without a closing fence the block is still being typed, so leave it alone.
		let closeNo = 0;
		for (let n = lineNo + 1; n <= doc.lines; n++) {
			if (FENCE_CLOSE.test(doc.line(n).text)) {
				closeNo = n;
				break;
			}
		}
		if (closeNo === 0) {
			break;
		}
		out.push({ from: line.from, to: doc.line(closeNo).to, openLine: lineNo, closeLine: closeNo });
		lineNo = closeNo + 1;
	}
	return out;
}

function buildMermaid(state: EditorState): DecorationSet {
	const { doc, selection: sel } = state;
	const dark = isDark();
	const ranges: Range<Decoration>[] = [];

	for (const fence of fenceRanges(doc)) {
		// Reveal raw when the cursor/selection intersects the block, matching
		// callouts and math.
		if (sel.ranges.some((r) => r.from <= fence.to && r.to >= fence.from)) {
			continue;
		}
		const code: string[] = [];
		for (let n = fence.openLine + 1; n < fence.closeLine; n++) {
			code.push(doc.line(n).text);
		}
		ranges.push(
			Decoration.replace({
				widget: new MermaidWidget(code.join("\n"), dark),
				block: true,
			}).range(fence.from, fence.to),
		);
	}

	const builder = new RangeSetBuilder<Decoration>();
	for (const r of ranges) {
		builder.add(r.from, r.to, r.value);
	}
	return builder.finish();
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
