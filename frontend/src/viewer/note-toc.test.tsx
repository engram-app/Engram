import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import NoteToc from "./note-toc";

const getView = vi.fn<() => EditorView | null>(() => null);

vi.mock("./editor/active-editor-context", () => ({
	useActiveEditor: () => ({ getView, setEditor: vi.fn(), hasEditor: getView() !== null }),
}));

const DOC = `# One

body

\`\`\`
# not a heading
\`\`\`

## Two

more

## Three
`;

describe("NoteToc", () => {
	it("ignores headings inside a fenced code block", () => {
		getView.mockReturnValue(null);
		render(<NoteToc content={DOC} />);

		expect(screen.queryByText("not a heading")).not.toBeInTheDocument();
		expect(screen.getAllByRole("link").map((a) => a.textContent)).toEqual(["One", "Two", "Three"]);
	});

	// Reading view has real heading elements with ids, so the browser's own
	// fragment scroll is correct there — don't hijack it.
	it("leaves the anchor alone when no editor is mounted", () => {
		getView.mockReturnValue(null);
		render(<NoteToc content={DOC} />);

		const event = new MouseEvent("click", { bubbles: true, cancelable: true });
		screen.getByRole("link", { name: "Two" }).dispatchEvent(event);

		expect(event.defaultPrevented).toBe(false);
	});

	// The editor is a CodeMirror document with NO anchorable heading elements,
	// so the hash used to land in the URL and nothing moved.
	it("scrolls the editor to the heading when one is mounted", () => {
		const view = new EditorView({ state: EditorState.create({ doc: DOC }) });
		const dispatch = vi.spyOn(view, "dispatch");
		getView.mockReturnValue(view);

		render(<NoteToc content={DOC} />);
		fireEvent.click(screen.getByRole("link", { name: "Three" }));

		expect(dispatch).toHaveBeenCalledOnce();
		// Offsets come from the ORIGINAL content. Stripping fences before
		// matching (the previous implementation) shifted every heading after a
		// code block, so this one would have scrolled to the wrong place.
		const arg = dispatch.mock.calls[0]?.[0] as { effects?: unknown };
		expect(arg.effects).toBeDefined();
		expect(DOC.startsWith("## Three", DOC.indexOf("## Three"))).toBe(true);
		view.destroy();
	});

	it("renders nothing for a note with fewer than two headings", () => {
		getView.mockReturnValue(null);
		const { container } = render(<NoteToc content={"# Only one\n\nbody\n"} />);

		expect(container).toBeEmptyDOMElement();
	});
});
