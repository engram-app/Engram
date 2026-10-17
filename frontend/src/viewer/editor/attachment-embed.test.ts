import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test, vi } from "vitest";
import { attachmentEmbeds } from "./attachment-embed";

let view: EditorView;
afterEach(() => view?.destroy());

const resolve = (target: string) => (target === "pic.png" ? "img/pic.png" : null);
const load = vi.fn((_path: string) => Promise.resolve("blob:pic"));

function mount(doc: string, anchor = doc.length) {
	view = new EditorView({
		state: EditorState.create({
			doc,
			selection: { anchor },
			extensions: [attachmentEmbeds({ resolve, load })],
		}),
		parent: document.body,
	});
	return view;
}

describe("attachmentEmbeds", () => {
	test("renders ![[image]] as an image fetched by its resolved path, doc untouched", async () => {
		const doc = "![[pic.png]]\n\ntail";
		mount(doc, doc.length);
		expect(view.state.doc.toString()).toBe(doc);
		const img = await vi.waitFor(() => {
			const el = view.dom.querySelector<HTMLImageElement>(".cm-attachment-embed img");
			expect(el).not.toBeNull();
			return el as HTMLImageElement;
		});
		expect(load).toHaveBeenCalledWith("img/pic.png");
		expect(img.getAttribute("src")).toBe("blob:pic");
	});

	test("reveals the raw source while the caret is on the embed", () => {
		mount("![[pic.png]]\n\ntail", 3);
		expect(view.dom.querySelector(".cm-attachment-embed")).toBeNull();
	});

	test("an |N alias sets the width", () => {
		mount("![[pic.png|120]]\n\ntail");
		const el = view.dom.querySelector<HTMLElement>(".cm-attachment-embed");
		expect(el?.style.width).toBe("120px");
	});

	test("leaves non-image targets, unresolved targets and fenced code alone", () => {
		mount("![[note.md]]\n![[nope.png]]\n```\n![[pic.png]]\n```\n\ntail");
		expect(view.dom.querySelector(".cm-attachment-embed")).toBeNull();
	});
});

test("an embed inside an indented code block or inline code stays literal", () => {
	view = new EditorView({
		state: EditorState.create({
			doc: "para\n\n\t![[pic.png]]\n\nuse `![[pic.png]]` here\n\ntail",
			selection: { anchor: 0 },
			extensions: [markdown({ base: markdownLanguage }), attachmentEmbeds({ resolve, load })],
		}),
		parent: document.body,
	});
	expect(view.dom.querySelector(".cm-attachment-embed")).toBeNull();
});
