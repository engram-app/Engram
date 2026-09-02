import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, it, vi } from "vitest";
import { linkOpenHandler } from "./link-open";

function mount(doc: string, openInApp: (href: string) => boolean) {
	const view = new EditorView({
		state: EditorState.create({
			doc,
			extensions: [
				markdown({ base: markdownLanguage }),
				// The real stack tags links via Atomic's inline-preview mark. Here the
				// class is applied by hand so the handler can be tested without
				// pulling in the whole preview pipeline.
				linkOpenHandler({ openInApp }),
			],
		}),
		parent: document.body,
	});
	// Stand in for the `.cm-atomic-link` mark decoration: wrap the link text in
	// a span CodeMirror can still resolve a document position for.
	const textNode = [...view.contentDOM.querySelectorAll(".cm-line")][0]?.firstChild;
	const span = document.createElement("span");
	span.className = "cm-atomic-link";
	textNode?.parentNode?.insertBefore(span, textNode);
	span.appendChild(textNode as ChildNode);
	return { view, span };
}

function clickOn(el: Element, init: MouseEventInit = {}) {
	el.dispatchEvent(new MouseEvent("click", { bubbles: true, button: 0, ...init }));
}

afterEach(() => {
	document.body.innerHTML = "";
	vi.restoreAllMocks();
});

describe("linkOpenHandler", () => {
	it("opens an external link in a new tab, never the current one", () => {
		const open = vi.spyOn(window, "open").mockReturnValue(null);
		const { span } = mount("[label](https://example.com/x)", () => false);

		clickOn(span);

		// `noopener` is not decoration: without it the opened page holds a
		// reference to this window and can navigate it away mid-edit.
		expect(open).toHaveBeenCalledWith("https://example.com/x", "_blank", "noopener,noreferrer");
	});

	it("routes an in-app target through the app instead of a new tab", () => {
		const open = vi.spyOn(window, "open").mockReturnValue(null);
		const openInApp = vi.fn().mockReturnValue(true);
		const { span } = mount("[label](Some-Note.md)", openInApp);

		clickOn(span);

		expect(openInApp).toHaveBeenCalledWith("Some-Note.md");
		expect(open).not.toHaveBeenCalled();
	});

	// The whole label is the hit target. Atomic scopes its own opener to a
	// trailing icon zone, and we suppress that icon — so a click anywhere but
	// the last ~1.25em used to do nothing at all.
	it("opens from the middle of the label, not just its trailing edge", () => {
		const open = vi.spyOn(window, "open").mockReturnValue(null);
		const { span } = mount("[a much longer label](https://example.com/y)", () => false);
		const inner = document.createTextNode("");
		span.appendChild(inner);

		clickOn(span);

		expect(open).toHaveBeenCalledOnce();
	});

	it("leaves modified clicks to the editor so multi-cursor still works", () => {
		const open = vi.spyOn(window, "open").mockReturnValue(null);
		const { span } = mount("[label](https://example.com/x)", () => false);

		clickOn(span, { metaKey: true });
		clickOn(span, { ctrlKey: true });
		clickOn(span, { shiftKey: true });
		clickOn(span, { altKey: true });

		expect(open).not.toHaveBeenCalled();
	});

	// An unescaped space makes this not a CommonMark link, so lezer emits no
	// Link node and Atomic never decorates it — it is not a link in Reading
	// mode either. Pinned so a future "why doesn't this open" is answered here.
	it("ignores a target with an unescaped space, which is not a link", () => {
		const open = vi.spyOn(window, "open").mockReturnValue(null);
		const openInApp = vi.fn().mockReturnValue(true);
		const { span } = mount("[label](Some Note.md)", openInApp);

		clickOn(span);

		expect(openInApp).not.toHaveBeenCalled();
		expect(open).not.toHaveBeenCalled();
	});

	it("ignores clicks outside a link", () => {
		const open = vi.spyOn(window, "open").mockReturnValue(null);
		const { view } = mount("plain text, no link", () => false);

		clickOn(view.contentDOM);

		expect(open).not.toHaveBeenCalled();
	});
});
