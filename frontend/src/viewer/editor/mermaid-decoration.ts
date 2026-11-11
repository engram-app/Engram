import { type EditorState, Prec } from "@codemirror/state";
import { type Command, Decoration, type EditorView, keymap, WidgetType } from "@codemirror/view";
import type { Translate } from "@/i18n/translate";
import { drawMermaid, rememberedMermaidHeight } from "../mermaid-render";
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
		private readonly dark: boolean,
		private readonly t: Translate,
	) {
		super();
	}

	// Includes `dark`: the palette is baked into the SVG rather than applied as
	// CSS, so a theme flip has to produce a NEW widget or the diagram keeps the
	// old colours. buildMermaid reads the theme, which is what makes this differ.
	eq(other: MermaidWidget) {
		return other.code === this.code && other.dark === this.dark && other.t === this.t;
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
			drawMermaid(el, "editor", this.code, this.dark, {
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

/** A fenced block: its mermaid source, or null for any other fence (or an unclosed one). */
type FenceToken = { code: string } | null;

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
 * Every fence, as tokens on the render core.
 *
 * Walks EVERY fence, not just the mermaid ones, and jumps the scan past each
 * one it finds. That is what stops a ```mermaid line QUOTED inside a wider
 * documentation fence from being read as a real block: it is content, and the
 * scanner never looks at it. Leading indentation up to three spaces is allowed,
 * so a fence inside a list item renders here as it already did in Reading mode.
 * Non-mermaid fences are tokens too, which is what makes a line outside every
 * fence a neutral point the core can resync at.
 *
 * Scanned rather than read off syntaxTree(state), which was tried and reverted:
 * the tree is parsed lazily, and fences below the parse frontier stopped
 * rendering. This scan only ever covers the lines an edit touched.
 *
 * ponytail: three spaces is the CommonMark document-level allowance, so a fence
 * indented further by a NESTED list item is still missed. Upgrade path is to
 * track container indentation; not worth it until someone hits it.
 *
 * The arrow-key commands below read these same tokens, so "where does this
 * block start" has one answer.
 */
const mermaidRenderer: TextRenderer<FenceToken> = {
	kind: "text",
	reveal: true,
	refresh: (tr) => tr.startState.facet(translator) !== tr.state.facet(translator),
	scan(state, from, emit, neutral) {
		const { doc } = state;
		let lineNo = doc.lineAt(from).number;
		while (lineNo <= doc.lines) {
			const line = doc.line(lineNo);
			if (line.from > from && neutral(line.from)) {
				return;
			}
			const open = FENCE_OPEN.exec(line.text);
			if (!open) {
				lineNo++;
				continue;
			}
			const indent = open.groups?.indent?.length ?? 0;
			const ticks = open.groups?.ticks?.length ?? 0;
			let closeNo = 0;
			for (let n = lineNo + 1; n <= doc.lines; n++) {
				const close = FENCE_CLOSE.exec(doc.line(n).text);
				if (close && (close.groups?.ticks?.length ?? 0) >= ticks) {
					closeNo = n;
					break;
				}
			}
			// No closer: the block is still being typed, and everything below is
			// inside it. One token to the end, never rendered.
			if (closeNo === 0) {
				emit({ from: line.from, to: doc.length, value: null });
				return;
			}
			let value: FenceToken = null;
			if (open.groups?.info === "mermaid") {
				const body: string[] = [];
				for (let n = lineNo + 1; n < closeNo; n++) {
					body.push(dedent(doc.line(n).text, indent));
				}
				value = { code: body.join("\n") };
			}
			emit({ from: line.from, to: doc.line(closeNo).to, value });
			// Past the whole block whether or not it was ours: everything between the
			// marks is content, including any line that looks like a fence.
			lineNo = closeNo + 1;
		}
	},
	decorate(state, t) {
		if (t.value === null) {
			return [];
		}
		return [
			Decoration.replace({
				widget: new MermaidWidget(t.value.code, isDark(), state.facet(translator)),
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
