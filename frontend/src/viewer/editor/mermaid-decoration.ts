import { type EditorState, Prec } from "@codemirror/state";
import { type Command, Decoration, type EditorView, keymap, WidgetType } from "@codemirror/view";
import type { Translate } from "@/i18n/translate";
import { drawMermaid, rememberedMermaidHeight } from "../mermaid-render";
import { fenceSurvives, scanFenced } from "./fence-scan";
import { defineRenderer, type TextRenderer, tokensAt } from "./render-core";
import { translator } from "./translator";
import "./mermaid.css";

// Keyed by DOM node, not held per widget: when a rebuilt widget is `eq` to the
// old one, CM6 keeps the DOM and later calls destroy(dom) on the NEW instance,
// whose own map would be empty, leaking the draw.
const drawCancels = new WeakMap<HTMLElement, () => void>();

/**
 * Renders one mermaid fence. The SVG arrives asynchronously, so toDOM returns an
 * empty container immediately and fills it later.
 */
class MermaidWidget extends WidgetType {
	constructor(
		private readonly code: string,
		private readonly t: Translate,
	) {
		super();
	}

	// No theme here: Pele colours come from CSS variables (mermaid-theme.css),
	// so a light/dark flip recolours the drawn SVG and the widget stays.
	eq(other: MermaidWidget) {
		return other.code === this.code && other.t === this.t;
	}

	toDOM(view: EditorView) {
		const el = document.createElement("div");
		el.className = "cm-mermaid-widget";
		// CM6 measured this widget's height while it was still empty. Once the SVG
		// lands the box grows, and without a re-measure the heightmap keeps the old
		// height — every line below the diagram then maps to the wrong screen
		// position, which shows up as clicks landing on the neighbouring line.
		const measure = () => view.requestMeasure();
		// Cancelled in destroy() if the widget goes first.
		drawCancels.set(
			el,
			drawMermaid(el, "editor", this.code, {
				drawn: measure,
				failed: (err) => {
					this.showError(el, err);
					measure();
				},
			}),
		);
		return el;
	}

	// The reservation drawMermaid holds, for CM6's heightmap before the widget
	// is measured.
	get estimatedHeight() {
		return rememberedMermaidHeight("editor", this.code) ?? -1;
	}

	destroy(dom: HTMLElement) {
		drawCancels.get(dom)?.();
	}

	// Show the diagram's own error rather than an empty box, and keep the source
	// visible so it can be fixed. Mermaid rejects on any syntax slip, which is a
	// normal state while typing.
	private showError(el: HTMLElement, err: unknown) {
		el.classList.add("cm-mermaid-error");
		// Mermaid's own message is third-party English: keep it verbatim, but tag
		// its language so the translated prefix and it are not read as one.
		const detail = document.createElement("span");
		detail.lang = "en";
		detail.textContent = err instanceof Error ? err.message : String(err);
		const { t } = this;
		const [before, after = ""] = t("Mermaid error: {error}", { error: "{error}" }).split("{error}");
		el.replaceChildren(before ?? "", detail, after);
	}

	// The widget is inert content, not a control; let clicks through so the caret
	// can be placed and the raw source revealed.
	ignoreEvent() {
		return false;
	}
}

/** A fenced block: its mermaid source, or null for any other fence (or an unclosed one). */
type FenceToken = { code: string } | null;

/**
 * Every fence, as tokens on the render core, through the shared fence scanner
 * (fence-scan.ts). It jumps the scan past each fence, which is what stops a
 * ```mermaid line QUOTED inside a wider documentation fence from being read as
 * a real block. Non-mermaid fences are tokens too, so a line outside every
 * fence is a neutral point the core can resync at, and an edit inside one that
 * does not close it costs nothing here.
 *
 * Scanned rather than read off syntaxTree(state), which was tried and reverted:
 * the tree is parsed lazily, and fences below the parse frontier stopped
 * rendering.
 *
 * The arrow-key commands below read these same tokens, so "where does this
 * block start" has one answer.
 */
const mermaidRenderer: TextRenderer<FenceToken> = {
	kind: "text",
	reveal: true,
	refresh: (tr) => tr.startState.facet(translator) !== tr.state.facet(translator),
	keep: (state, t, from, to) => t.value === null && fenceSurvives(state.doc, t, from, to),
	scan(state, from, emit, neutral) {
		const { doc } = state;
		scanFenced(state, from, neutral, (fence) => {
			let value: FenceToken = null;
			// An unclosed fence is still being typed: never rendered.
			if (fence.closeLine && fence.info === "mermaid") {
				const body: string[] = [];
				for (let n = fence.openLine + 1; n < fence.closeLine; n++) {
					body.push(dedent(doc.line(n).text, fence.indent));
				}
				value = { code: body.join("\n") };
			}
			emit({ from: fence.from, to: fence.to, value });
		});
	},
	decorate(state, t) {
		if (t.value === null) {
			return [];
		}
		return [
			Decoration.replace({
				widget: new MermaidWidget(t.value.code, state.facet(translator)),
				block: true,
			}).range(t.from, t.to),
		];
	},
};

/** The rendered (mermaid) fence starting or ending at `pos`, if any. */
function mermaidAt(state: EditorState, pos: number, edge: "from" | "to") {
	return tokensAt(state, mermaidRenderer, pos, pos).find(
		(t) => t.value !== null && t[edge] === pos,
	);
}

/** Drop up to `width` leading spaces, so an indented diagram reaches mermaid flush. */
function dedent(line: string, width: number): string {
	let i = 0;
	while (i < width && line[i] === " ") {
		i++;
	}
	return line.slice(i);
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
	// Already inside: the block is revealed and normal motion is what should
	// carry the caret through its lines.
	if (tokensAt(state, mermaidRenderer, range.head, range.head).some((t) => t.value !== null)) {
		return false;
	}
	// Enter at the near edge, so continuing in the same direction reads the
	// source in the order you were already travelling.
	const neighbour = caretLine + (forward ? 1 : -1);
	if (neighbour < 1 || neighbour > doc.lines) {
		return false;
	}
	const line = doc.line(neighbour);
	const fence = forward ? mermaidAt(state, line.from, "from") : mermaidAt(state, line.to, "to");
	if (!fence) {
		return false;
	}
	view.dispatch({ selection: { anchor: forward ? fence.from : fence.to }, scrollIntoView: true });
	return true;
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
 * On the render core, so a StateField underneath: a mermaid fence is always
 * multi-line, its replace decoration spans line breaks, and CM6 only accepts
 * those from a state field. A keystroke rescans the fence it is in; a widget
 * whose source did not change is `eq` and keeps its drawn diagram.
 *
 * View-only. It decorates the markdown source and never mutates
 * EditorState.doc, leaving the yCollab Y.Text binding untouched.
 */
export const mermaidDecoration = defineRenderer(mermaidRenderer);

export { mermaidRenderer };
