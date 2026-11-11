import type { Range } from "@codemirror/state";
import { Decoration, WidgetType } from "@codemirror/view";
import { defaultConfig } from "@portaljs/remark-callouts";
import "./callout.css";
import { defineRenderer, type TextRenderer } from "./render-core";

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

// The map is third-party note-driven data, so an entry can be any shape.
function isCalloutStyle(v: unknown): v is CalloutStyle {
	return (
		typeof v === "object" &&
		v !== null &&
		"keyword" in v &&
		typeof v.keyword === "string" &&
		"color" in v &&
		typeof v.color === "string" &&
		"svg" in v &&
		typeof v.svg === "string"
	);
}

/**
 * Resolve a callout type to its icon + color using the SAME map Reading mode
 * renders from (`@portaljs/remark-callouts`), so the two views can't drift.
 * `types` holds base entries (`tip: {keyword, color, svg}`) plus alias strings
 * (`important: "tip"`), which is one hop to follow.
 */
function resolveStyle(type: string): CalloutStyle | null {
	const { types } = defaultConfig;
	// `type` is note content, so the lookup must be own-property-only: a plain
	// object answers `types["__proto__"]` with Object.prototype, which passes a
	// bare `typeof === "object"` check and yields an all-undefined style.
	if (!Object.hasOwn(types, type)) {
		return null;
	}
	const entry = types[type];
	const base = typeof entry === "string" ? types[entry] : entry;
	return isCalloutStyle(base) ? base : null;
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

/**
 * Callout blocks: a `> [!type]` header and the `>` lines under it. One token per
 * block; a line outside a block carries no state, so it is neutral. Revealed raw
 * while the selection touches the block.
 */
export const calloutRenderer: TextRenderer<string> = {
	kind: "text",
	reveal: true,
	scan(state, from, emit, neutral) {
		const { doc } = state;
		let lineNo = doc.lineAt(from).number;
		while (lineNo <= doc.lines) {
			const line = doc.line(lineNo);
			if (line.from > from && neutral(line.from)) {
				return;
			}
			const m = CALLOUT_START_RE.exec(line.text);
			if (!m) {
				lineNo++;
				continue;
			}
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
			emit({
				from: line.from,
				to: doc.line(endLineNo).to,
				value: (m.groups?.type ?? "").toLowerCase(),
			});
			lineNo = endLineNo + 1;
		}
	},
	decorate(state, t) {
		const { doc } = state;
		const type = t.value;
		const style = resolveStyle(type);
		const attributes: Record<string, string> = { class: `cm-callout cm-callout-${type}` };
		if (style) {
			attributes.style = `--callout-color:${style.color}`;
		}
		const deco = Decoration.line({ attributes });
		const header = doc.lineAt(t.from);
		const out: Range<Decoration>[] = [deco.range(header.from)];
		if (style) {
			// The header line's line decoration lands first (same `from`, lower
			// startSide); the set is sorted, so order here is for the reader.
			const head = CALLOUT_START_RE.exec(header.text)?.[0].length ?? 0;
			const title = header.text.slice(head).trim() || capitalize(style.keyword);
			out.push(
				Decoration.replace({ widget: new CalloutTitleWidget(style.svg, title) }).range(
					header.from,
					header.to,
				),
			);
		}
		for (let n = header.number + 1; n <= doc.lineAt(t.to).number; n++) {
			out.push(deco.range(doc.line(n).from));
		}
		return out;
	},
};

export const calloutDecoration = defineRenderer(calloutRenderer);
