import { readOnlyExtension, tables } from "@atomic-editor/editor";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test, vi } from "vitest";

// @atomic-editor/editor's table cells only parsed bold/italic/strike/
// highlight/links, so `[[wikilink]]` and `inline code` rendered as literal
// text. Patched in patches/@atomic-editor%2Feditor@*.

let view: EditorView;
afterEach(() => view?.destroy());

function mountCell(
	cellMarkdown: string,
	opts: { readOnly?: boolean; onWikiLinkClick?: (t: string) => void } = {},
): HTMLElement {
	const doc = `| h |\n| --- |\n| ${cellMarkdown} |\n`;
	view = new EditorView({
		state: EditorState.create({
			doc,
			extensions: [
				markdown({ base: markdownLanguage }),
				tables({ onWikiLinkClick: opts.onWikiLinkClick }),
				...(opts.readOnly ? [readOnlyExtension(true)] : []),
			],
		}),
		parent: document.body,
	});
	const [, cell] = view.dom.querySelectorAll<HTMLElement>(".cm-atomic-table-cell-source"); // skip the header cell
	if (!cell) {
		throw new Error("table widget did not render");
	}
	return cell;
}

function click(el: Element) {
	el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
}

describe("table cell inline code", () => {
	test("renders `code` as an inline-code span", () => {
		const cell = mountCell("a `some code` b");
		const code = cell.querySelector(".cm-atomic-inline-code");
		expect(code?.textContent).toBe("some code");
	});

	test("keeps the backticks in textContent so the cell round-trips", () => {
		const cell = mountCell("a `some code` b");
		expect(cell.textContent).toBe("a `some code` b");
	});

	test("does not parse marks inside code", () => {
		const cell = mountCell("`**not bold**`");
		expect(cell.querySelector(".cm-atomic-strong")).toBeNull();
		expect(cell.querySelector(".cm-atomic-inline-code")?.textContent).toBe("**not bold**");
	});

	test("an unclosed backtick stays literal", () => {
		const cell = mountCell("a ` b");
		expect(cell.querySelector(".cm-atomic-inline-code")).toBeNull();
		expect(cell.textContent).toBe("a ` b");
	});
});

describe("table cell wikilinks", () => {
	test("renders [[target]] as a wikilink showing the target", () => {
		const cell = mountCell("see [[Table Test]] now");
		const link = cell.querySelector<HTMLElement>(".cm-atomic-wiki-link");
		expect(link?.textContent).toBe("Table Test");
		expect(link?.dataset.wikiLinkTarget).toBe("Table Test");
	});

	// In a GFM table the pipe must be escaped (`\\|`) or it splits the cell.
	test("[[target|alias]] shows the alias but targets the note", () => {
		const cell = mountCell("[[Table Test\\|the table]]");
		const link = cell.querySelector<HTMLElement>(".cm-atomic-wiki-link");
		expect(link?.textContent).toBe("the table");
		expect(link?.dataset.wikiLinkTarget).toBe("Table Test");
	});

	test("keeps the brackets in textContent; the cell pipe is unescaped in the DOM", () => {
		const cell = mountCell("see [[Table Test\\|the table]] now");
		expect(cell.textContent).toBe("see [[Table Test|the table]] now");
	});

	test("an unclosed [[ stays literal", () => {
		const cell = mountCell("see [[Table Test now");
		expect(cell.querySelector(".cm-atomic-wiki-link")).toBeNull();
	});

	test("clicking a wikilink opens its target (read-only)", () => {
		const onWikiLinkClick = vi.fn();
		const cell = mountCell("[[Table Test\\|the table]]", { readOnly: true, onWikiLinkClick });
		const link = cell.querySelector(".cm-atomic-wiki-link");
		expect(link).not.toBeNull();
		click(link as Element);
		expect(onWikiLinkClick).toHaveBeenCalledExactlyOnceWith("Table Test");
	});

	test("clicking a wikilink opens its target (editing)", () => {
		const onWikiLinkClick = vi.fn();
		const cell = mountCell("[[Table Test]]", { onWikiLinkClick });
		click(cell.querySelector(".cm-atomic-wiki-link") as Element);
		expect(onWikiLinkClick).toHaveBeenCalledExactlyOnceWith("Table Test");
	});

	test("clicking plain cell text does not open anything", () => {
		const onWikiLinkClick = vi.fn();
		const cell = mountCell("plain [[Table Test]]", { onWikiLinkClick });
		click(cell);
		expect(onWikiLinkClick).not.toHaveBeenCalled();
	});

	test("a wikilink with no handler configured does not throw", () => {
		const cell = mountCell("[[Table Test]]");
		expect(() => click(cell.querySelector(".cm-atomic-wiki-link") as Element)).not.toThrow();
	});

	test("the wikilink survives a round-trip through the markdown doc", () => {
		mountCell("see [[Table Test\\|the table]]");
		expect(view.state.doc.toString()).toContain("| see [[Table Test\\|the table]] |");
	});
});
