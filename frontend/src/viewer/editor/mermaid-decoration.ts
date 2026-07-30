import { type EditorState, type Range, RangeSetBuilder, StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, WidgetType } from "@codemirror/view";
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

function buildMermaid(state: EditorState): DecorationSet {
	const { doc, selection: sel } = state;
	const dark = isDark();
	const ranges: Range<Decoration>[] = [];

	let lineNo = 1;
	while (lineNo <= doc.lines) {
		const line = doc.line(lineNo);
		if (!FENCE_OPEN.test(line.text)) {
			lineNo++;
			continue;
		}
		// Find the closing fence. Without one the block is still being typed, so
		// leave every line of it alone.
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

		const { from } = line;
		const { to } = doc.line(closeNo);
		// Reveal raw when the cursor/selection intersects the block, matching
		// callouts and math.
		const active = sel.ranges.some((r) => r.from <= to && r.to >= from);
		if (!active) {
			const code: string[] = [];
			for (let n = lineNo + 1; n < closeNo; n++) {
				code.push(doc.line(n).text);
			}
			ranges.push(
				Decoration.replace({
					widget: new MermaidWidget(code.join("\n"), dark),
					block: true,
				}).range(from, to),
			);
		}
		lineNo = closeNo + 1;
	}

	const builder = new RangeSetBuilder<Decoration>();
	for (const r of ranges) {
		builder.add(r.from, r.to, r.value);
	}
	return builder.finish();
}

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
