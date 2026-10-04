import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { foldGutter } from "@codemirror/language";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { fireEvent, render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import * as Y from "yjs";
import { addKey } from "../crdt/frontmatter-doc";
import { uploadFilesTo } from "./attachment-upload/upload-files";
import { headingFoldWith } from "./editor/heading-fold";
import { translator } from "./editor/translator";
import { PropertiesWidget } from "./properties-widget";
import { DeleteConfirm } from "./tree-actions/delete-confirm";

const { toastError } = vi.hoisted(() => ({ toastError: vi.fn() }));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: toastError } }));
vi.mock("./attachment-upload/file-to-base64", () => ({
	fileToBase64: () => Promise.resolve("AAAA"),
}));

test("DeleteConfirm counts a folder's items with the plural form", () => {
	const { rerender } = render(
		<DeleteConfirm
			nodes={[{ kind: "folder", path: "src", childCount: 1 }]}
			onConfirm={() => {}}
			onCancel={() => {}}
		/>,
	);
	expect(screen.getByText("Delete src/ and 1 item?")).toBeInTheDocument();
	rerender(
		<DeleteConfirm
			nodes={[{ kind: "folder", path: "src", childCount: 4 }]}
			onConfirm={() => {}}
			onCancel={() => {}}
		/>,
	);
	expect(screen.getByText("Delete src/ and 4 items?")).toBeInTheDocument();
});

test("the properties help reads as whole sentences with its slots rendered", () => {
	const doc = new Y.Doc();
	addKey(doc, "title", "text");
	render(<PropertiesWidget doc={doc} />);
	fireEvent.click(screen.getByRole("button", { name: "About properties" }));
	const emphasis = screen.getByText("frontmatter");
	expect(emphasis.tagName).toBe("STRONG");
	expect(emphasis.closest("p")?.textContent).toBe(
		"Properties are the note's frontmatter: a block at the very top of the file, fenced by ---. Obsidian shows the same block as Properties, so a note edited in either place reads the same in both.",
	);
	expect(screen.getByText("---").tagName).toBe("CODE");
});

test("uploadFilesTo reports a failure through the translate function it is given", async () => {
	toastError.mockReset();
	const upload = vi.fn().mockRejectedValue(new Error("boom"));
	const t = (en: string, vars?: Record<string, string | number>) =>
		`[${en.replace("{name}", String(vars?.name))}]`;
	await uploadFilesTo({
		upload,
		existing: [],
		files: [new File(["x"], "a.png")],
		folder: "",
		t,
	});
	expect(toastError).toHaveBeenCalledWith("[Couldn't upload a.png]");
});

test("the translator facet defaults to English and carries the editor's translate function", () => {
	const t = (en: string) => `<${en}>`;
	const view = new EditorView({
		state: EditorState.create({
			doc: "# Title\n\nbody\n",
			extensions: [markdown({ base: markdownLanguage }), headingFoldWith(t), translator.of(t)],
		}),
		parent: document.body,
	});
	expect(view.state.facet(translator)("Link suggestions")).toBe("<Link suggestions>");
	const bare = EditorState.create({ extensions: [foldGutter()] });
	expect(bare.facet(translator)("Link suggestions")).toBe("Link suggestions");
	view.destroy();
});
