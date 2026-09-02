import { syntaxTree } from "@codemirror/language";
import { type Extension, Prec } from "@codemirror/state";
import { EditorView } from "@codemirror/view";

/**
 * Click-to-open for markdown links in the editor.
 *
 * Atomic's own handler scopes the open affordance to a trailing icon hit-zone
 * (`linkIconHitTarget`) so the link TEXT stays clickable-to-edit. We suppress
 * that icon in obsidian-theme.css — it renders between the `]` and the `(`,
 * which reads as a typo in the middle of the syntax you are editing — and
 * suppressing it left a hit-zone with nothing in it: the last 1.25em of the
 * label opened the link and the rest did nothing, which reads as "links don't
 * work in edit mode".
 *
 * So the whole link opens on a plain click, matching Obsidian's Live Preview
 * and Reading mode here. Raw mode is where you click INTO link text to edit it.
 */
interface LinkOpenOpts {
	/** In-app navigation for a link that resolves to a note. Return false to
	 *  fall through to `window.open` (external URL, anchor, unresolvable). */
	openInApp: (href: string) => boolean;
}

/** Schemes that may reach `window.open`.
 *
 *  Reading mode gets this for free — react-markdown's `defaultUrlTransform`
 *  drops unsafe schemes before an href is ever rendered. The editor path reads
 *  the destination straight out of the DOCUMENT, so `[x](javascript:…)` typed
 *  into a note would otherwise be handed to `window.open` verbatim. Relative
 *  targets and `#anchor` land here too when they do not resolve to a note, and
 *  opening a junk tab for those is its own small bug. */
const OPENABLE = /^(?:https?:|mailto:)/iu;

/** Everything that is not an in-app note reference opens in a new tab. */
function openExternal(url: string): void {
	if (!OPENABLE.test(url)) {
		return;
	}
	// `noopener` matters: without it the opened page gets a handle on our
	// window via `opener` and can navigate the app away from under an
	// unsaved edit.
	window.open(url, "_blank", "noopener,noreferrer");
}

/** The destination of the `Link` node containing `pos`, or null if `pos` is
 *  not inside one.
 *
 *  Sliced between the `(` and the closing `)` rather than read off a `URL`
 *  child: lezer only tags a bare, space-free destination as `URL`, so
 *  `[label](Some Note.md)` — an ordinary Obsidian-style link to a note whose
 *  name has a space — has a Link node with no URL child at all.
 *
 *  Marks are matched AFTER the label's closing `]` because a link whose label
 *  is itself a url (`[https://label](https://dest)`) has two url-ish runs and
 *  only the second is the destination. */
function linkUrlAt(view: EditorView, pos: number): string | null {
	let node = syntaxTree(view.state).resolveInner(pos, 1);
	while (node.parent && node.name !== "Link") {
		node = node.parent;
	}
	if (node.name !== "Link") {
		return null;
	}
	const { doc } = view.state;
	const marks = node.getChildren("LinkMark");
	const labelClose = marks.find((m) => doc.sliceString(m.from, m.to) === "]");
	if (!labelClose) {
		return null;
	}
	const open = marks.find((m) => m.from >= labelClose.to && doc.sliceString(m.from, m.to) === "(");
	const close = [...marks]
		.reverse()
		.find((m) => open && m.from >= open.to && doc.sliceString(m.from, m.to) === ")");
	if (!(open && close)) {
		return null;
	}
	// A link title (`[a](url "title")`) is not part of the destination.
	const title = node.getChildren("LinkTitle").find((t) => t.from >= open.to);
	const text = doc.sliceString(open.to, title ? title.from : close.from).trim();
	return text === "" ? null : text;
}

export function linkOpenHandler(opts: LinkOpenOpts): Extension {
	// Prec.highest so this runs before Atomic's own icon-scoped handler; both
	// return true on a hit, and CM6 stops at the first handler that does.
	return Prec.highest(
		EditorView.domEventHandlers({
			click: (event, view) => {
				// Modified clicks stay with the editor: cmd/ctrl-click is the
				// multi-cursor gesture, and shift-click extends a selection.
				if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
					return false;
				}
				if (event.button !== 0) {
					return false;
				}
				const { target } = event;
				if (!(target instanceof Element)) {
					return false;
				}
				// Wikilinks render their own widget and are opened by Atomic's
				// `wikiLinks` extension; `.cm-atomic-link` is markdown links and
				// bare autolinks only.
				const linkEl = target.closest(".cm-atomic-link");
				if (!(linkEl && view.contentDOM.contains(linkEl))) {
					return false;
				}
				const pos = view.posAtDOM(linkEl);
				if (pos < 0) {
					return false;
				}
				// A bare autolink (`https://…`) has no Link node — it is a URL node
				// standing alone, and its own text IS the destination. Scoped to
				// that case: falling back whenever `linkUrlAt` returns null handed
				// the raw `[label](target)` source over as an href.
				const url =
					linkUrlAt(view, pos) ??
					(syntaxTree(view.state).resolveInner(pos, 1).name === "URL"
						? linkEl.textContent?.trim()
						: null);
				if (!url) {
					return false;
				}
				event.preventDefault();
				event.stopPropagation();
				if (!opts.openInApp(url)) {
					openExternal(url);
				}
				return true;
			},
		}),
	);
}
