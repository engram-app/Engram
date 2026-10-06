import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { useEffect } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { LocaleProvider } from "@/i18n/locale-provider";
import { ThemeProvider } from "../../theme/theme-provider";
import { ActiveEditorProvider, useActiveEditor } from "../editor/active-editor-context";
import MarkdownReferencePanel from "./markdown-reference-panel";

vi.setConfig({ testTimeout: 20_000 });
vi.mock("../../billing/use-is-free-tier", () => ({ useIsFreeTier: () => false }));

const GERMAN = {
	"Claim.": "Behauptung.",
	"Source.": "Quelle.",
	"Shipped on time.": "Pünktlich geliefert.",
	"For a generous value of on time.": "Bei großzügiger Auslegung von pünktlich.",
	"Worth knowing, but not urgent.": "Gut zu wissen, aber nicht dringend.",
};
const loaders = { de: async () => ({ default: GERMAN }) };

let view: EditorView | null = null;
beforeEach(() => window.localStorage.setItem("engram:locale", "de"));
afterEach(() => {
	view?.destroy();
	view = null;
	window.localStorage.clear();
});

function Publisher({ editor }: { editor: EditorView }) {
	const { setEditor } = useActiveEditor();
	useEffect(() => {
		setEditor(() => editor);
	}, [editor, setEditor]);
	return null;
}

function renderGerman() {
	view = new EditorView({
		state: EditorState.create({ doc: "prose", selection: { anchor: 5 } }),
		parent: document.body,
	});
	return render(
		<LocaleProvider loaders={loaders}>
			<ThemeProvider>
				<ActiveEditorProvider>
					<Publisher editor={view} />
					<MarkdownReferencePanel />
				</ActiveEditorProvider>
			</ThemeProvider>
		</LocaleProvider>,
	);
}

function footnoteRow(): HTMLElement {
	const li = [...document.querySelectorAll("li")].find((el) =>
		[...el.querySelectorAll("p")].some((p) => p.textContent === "Footnote"),
	);
	if (!li) {
		throw new Error("no Footnote row");
	}
	return li;
}

describe("MarkdownReferencePanel with a German catalog", () => {
	it("shows, previews and inserts the translated sample, keeping the syntax", async () => {
		renderGerman();
		const details = [...document.querySelectorAll("summary")]
			.find((el) => (el.textContent ?? "").startsWith("Structure"))
			?.closest("details");
		if (!details) {
			throw new Error("no Structure section");
		}
		details.open = true;
		fireEvent(details, new Event("toggle"));

		await waitFor(() =>
			expect(footnoteRow().querySelector("pre")?.textContent).toBe(
				"Behauptung.[^1]\n\n[^1]: Quelle.",
			),
		);
		await waitFor(() =>
			expect(footnoteRow().querySelector("figure")?.textContent).toContain("Pünktlich geliefert"),
		);
		expect(footnoteRow().querySelector("figure")?.textContent).toContain("Bei großzügiger");

		fireEvent.click(within(footnoteRow()).getByRole("button", { name: /^Insert / }));
		expect(view?.state.doc.toString()).toContain("Behauptung.[^1]\n\n[^1]: Quelle.");
	});

	it("still finds an entry by its English keyword", async () => {
		renderGerman();
		fireEvent.change(await screen.findByRole("searchbox"), { target: { value: "citation" } });
		await waitFor(() => expect(footnoteRow()).toBeInTheDocument());
	});
});
