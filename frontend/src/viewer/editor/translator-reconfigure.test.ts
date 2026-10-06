import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { foldAll } from "@codemirror/language";
import { EditorState, type Extension } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test, vi } from "vitest";
import type { Translate } from "@/i18n/translate";
import { attachmentEmbeds } from "./attachment-embed";
import { headingFoldWith } from "./heading-fold";
import { mermaidDecoration } from "./mermaid-decoration";
import { translator, translatorCompartment } from "./translator";

vi.mock("../mermaid-render", () => ({
	nextMermaidId: () => "m1",
	renderMermaid: () => Promise.reject(new Error("bad diagram")),
}));

// A language switch must repaint widgets that are ALREADY on screen, in place:
// same view, same doc, same selection.
const en: Translate = (s, vars) =>
	s.replace(/\{(?<k>\w+)\}/gu, (_m, k: string) => String(vars?.[k] ?? ""));
const de: Translate = (s, vars) => `de:${en(s, vars)}`;

let view: EditorView;
afterEach(() => view?.destroy());

function mount(doc: string, extensions: Extension[]) {
	view = new EditorView({
		state: EditorState.create({
			doc,
			selection: { anchor: 1 },
			extensions: [
				markdown({ base: markdownLanguage }),
				translatorCompartment.of(translator.of(en)),
				...extensions,
			],
		}),
		parent: document.body,
	});
	return view;
}

/** Switches to German and reports whether view, doc and selection all survived untouched. */
function switchToGerman(): boolean {
	const { state: before } = view;
	const v = view;
	view.dispatch({ effects: translatorCompartment.reconfigure(translator.of(de)) });
	return view === v && view.state.doc === before.doc && view.state.selection === before.selection;
}

describe("widgets follow a translator change in place", () => {
	test("fold gutter chevron aria-label", async () => {
		mount("# One\n\nbody\n\n# Two\n\nmore\n", [headingFoldWith(en)]);
		view.dispatch({ selection: { anchor: 1 } });
		await vi.waitFor(() => expect(view.dom.querySelector(".cm-fold-chevron")).not.toBeNull());
		const label = () => view.dom.querySelector(".cm-fold-chevron")?.getAttribute("aria-label");
		const initial = label();
		expect(initial).toMatch(/^(?:Collapse|Expand) section$/u);
		expect(switchToGerman()).toBe(true);
		expect(label()).toBe(`de:${initial}`);
	});

	test("fold placeholder title and aria-label", () => {
		mount("# One\n\nbody\n\n# Two\n\nmore\n", [headingFoldWith(en)]);
		foldAll(view);
		const el = () => view.dom.querySelector(".cm-foldPlaceholder");
		expect(el()?.getAttribute("aria-label")).toBe("Expand section");
		expect(switchToGerman()).toBe(true);
		expect(el()?.getAttribute("aria-label")).toBe("de:Expand section");
		expect(el()?.getAttribute("title")).toBe("de:Expand section");
	});

	test("attachment embed load-error text", async () => {
		mount("x ![[pic.png]] y\n", [
			attachmentEmbeds({ resolve: (t) => t, load: () => Promise.reject(new Error("no")) }),
		]);
		view.dispatch({ selection: { anchor: 0 } });
		const text = () => view.dom.querySelector(".cm-attachment-embed-error")?.textContent;
		await vi.waitFor(() => expect(text()).toBe("Couldn't load pic.png"));
		expect(switchToGerman()).toBe(true);
		await vi.waitFor(() => expect(text()).toBe("de:Couldn't load pic.png"));
	});

	test("mermaid error text", async () => {
		mount("a\n\n```mermaid\ngraph LR\n```\n", [mermaidDecoration]);
		view.dispatch({ selection: { anchor: 0 } });
		const text = () => view.dom.querySelector(".cm-mermaid-error")?.textContent;
		await vi.waitFor(() => expect(text()).toBe("Mermaid error: bad diagram"));
		expect(switchToGerman()).toBe(true);
		await vi.waitFor(() => expect(text()).toBe("de:Mermaid error: bad diagram"));
	});
});
