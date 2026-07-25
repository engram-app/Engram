import { RangeSetBuilder } from "@codemirror/state";
import {
	Decoration,
	type DecorationSet,
	type EditorView,
	ViewPlugin,
	type ViewUpdate,
	WidgetType,
} from "@codemirror/view";
import { defaultConfig } from "@portaljs/remark-callouts";
import "./callout.css";

// First line of a callout block: `> [!type]`, an optional fold marker (`+`/`-`),
// optionally followed by a title.
const CALLOUT_START_RE = /^>\s*\[!(?<type>\w+)\][+-]?/;
// Any blockquote continuation line.
const BLOCKQUOTE_LINE_RE = /^>/;

interface CalloutStyle {
	keyword: string;
	color: string;
	svg: string;
}

/**
 * Resolve a callout type to its icon + color using the SAME map Reading mode
 * renders from (`@portaljs/remark-callouts`), so the two views can't drift.
 * `types` holds base entries (`tip: {keyword, color, svg}`) plus alias strings
 * (`important: "tip"`), which is one hop to follow.
 */
function resolveStyle(type: string): CalloutStyle | null {
	const entry = defaultConfig.types[type];
	const base = typeof entry === "string" ? defaultConfig.types[entry] : entry;
	return base && typeof base === "object" ? (base as CalloutStyle) : null;
}

const capitalize = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/** Replaces the raw `> [!type] Title` header line with icon + title. */
class CalloutTitleWidget extends WidgetType {
	constructor(
		private readonly svg: string,
		private readonly title: string,
	) {
		super();
	}
	eq(other: CalloutTitleWidget) {
		return other.svg === this.svg && other.title === this.title;
	}
	toDOM() {
		const el = document.createElement("span");
		el.className = "cm-callout-title";
		// Trusted constant from the callout map, not user content.
		el.innerHTML = this.svg;
		el.append(this.title);
		return el;
	}
	ignoreEvent() {
		return false;
	}
}

function buildCallouts(view: EditorView): DecorationSet {
	const { doc, selection: sel } = view.state;
	const builder = new RangeSetBuilder<Decoration>();
	// ponytail: whole-doc scan; fine for typical note sizes. Same tradeoff as
	// katex-decoration.ts — view.visibleRanges is empty under happy-dom.
	let lineNo = 1;
	while (lineNo <= doc.lines) {
		const line = doc.line(lineNo);
		const m = CALLOUT_START_RE.exec(line.text);
		if (!m) {
			lineNo++;
			continue;
		}
		const type = (m.groups?.type ?? "").toLowerCase();
		let endLineNo = lineNo;
		while (endLineNo + 1 <= doc.lines) {
			const nextText = doc.line(endLineNo + 1).text;
			// A new `> [!type]` header always starts a fresh block, even though
			// it also matches the blockquote continuation regex.
			if (!BLOCKQUOTE_LINE_RE.test(nextText) || CALLOUT_START_RE.test(nextText)) {
				break;
			}
			endLineNo++;
		}
		const blockFrom = line.from;
		const blockTo = doc.line(endLineNo).to;
		// Reveal raw when the cursor/selection intersects the block.
		const active = sel.ranges.some((r) => r.from <= blockTo && r.to >= blockFrom);
		if (!active) {
			const style = resolveStyle(type);
			const attributes: Record<string, string> = {
				class: `cm-callout cm-callout-${type}`,
			};
			if (style) {
				attributes.style = `--callout-color:${style.color}`;
			}
			const deco = Decoration.line({ attributes });
			builder.add(line.from, line.from, deco);
			if (style) {
				// The header line's line-decoration must land first (same `from`, lower
				// startSide), and the replace before any later line — RangeSetBuilder
				// only accepts ranges in (from, startSide) order.
				const title = line.text.slice(m[0].length).trim() || capitalize(style.keyword);
				builder.add(
					line.from,
					line.to,
					Decoration.replace({ widget: new CalloutTitleWidget(style.svg, title) }),
				);
			}
			for (let n = lineNo + 1; n <= endLineNo; n++) {
				builder.add(doc.line(n).from, doc.line(n).from, deco);
			}
		}
		lineNo = endLineNo + 1;
	}
	return builder.finish();
}

export const calloutDecoration = ViewPlugin.fromClass(
	class {
		decorations: DecorationSet;
		constructor(view: EditorView) {
			this.decorations = buildCallouts(view);
		}
		update(u: ViewUpdate) {
			if (u.docChanged || u.selectionSet || u.viewportChanged) {
				this.decorations = buildCallouts(u.view);
			}
		}
	},
	{ decorations: (v) => v.decorations },
);
