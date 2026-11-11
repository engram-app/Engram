import { language } from "@codemirror/language";
import type { EditorView } from "@codemirror/view";
import { act, render } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Awareness } from "y-protocols/awareness";
import * as Y from "yjs";
import { englishT } from "@/i18n/translate";
import type { LivePreviewOpts } from "./editor/live-preview";
import NoteEditor from "./note-editor";

// Every livePreviewExtensions call is a new markdown Language, i.e. a full
// re-parse of the note (the "whole doc flashes unhighlighted" bug). Record the
// options each call got so tests can count rebuilds and call the callbacks.
const built = vi.hoisted(() => [] as LivePreviewOpts[]);
vi.mock("./editor/live-preview", async (importOriginal) => {
	const actual = await importOriginal<typeof import("./editor/live-preview")>();
	return {
		...actual,
		livePreviewExtensions: (opts: LivePreviewOpts) => {
			built.push(opts);
			return actual.livePreviewExtensions(opts);
		},
	};
});
vi.mock("../theme/theme-provider", () => ({ useTheme: () => ({ resolved: "light" }) }));
vi.mock("@/i18n/locale-provider", () => ({
	useT: () => ({ t: englishT, renderedLocale: "en" }),
}));
vi.mock("../api/queries", () => ({
	useAttachments: () => ({ data: [] }),
	useUploadAttachment: () => ({ mutateAsync: vi.fn() }),
}));

function callbacks() {
	return {
		resolveWikiLink: vi.fn((n: string) => `/w/${n}`),
		openWikiLink: vi.fn(),
		wikiCompletionPaths: vi.fn(() => ["a.md"]),
		openMarkdownLink: vi.fn(() => false),
	};
}

function mount() {
	const doc = new Y.Doc();
	const ytext = doc.getText("content");
	ytext.insert(0, "- one\n- two\n");
	const awareness = new Awareness(doc);
	let view: EditorView | null = null;
	const onView = (v: EditorView | null) => {
		view = v;
	};
	const ui = (mode: "rendered" | "raw", cbs: ReturnType<typeof callbacks>) => (
		<NoteEditor ytext={ytext} awareness={awareness} mode={mode} onView={onView} {...cbs} />
	);
	const first = callbacks();
	const r = render(ui("rendered", first));
	return {
		first,
		rerender: (mode: "rendered" | "raw", cbs: ReturnType<typeof callbacks>) =>
			act(() => r.rerender(ui(mode, cbs))),
		lang: () => (view as EditorView | null)?.state.facet(language),
	};
}

afterEach(() => {
	built.length = 0;
});

describe("NoteEditor decorations compartment", () => {
	// Typing re-renders NotePage, and its link callbacks get new identities
	// (useCreateNote() returns a fresh object every render). Each new identity
	// used to reconfigure the compartment, rebuild the markdown language and
	// re-parse the whole note: list text flashed to unhighlighted on every edit.
	it("does not rebuild the markdown language when only callback identities change", () => {
		const m = mount();
		const before = m.lang();
		expect(built).toHaveLength(1);

		m.rerender("rendered", callbacks());
		m.rerender("rendered", callbacks());

		expect(built).toHaveLength(1);
		expect(m.lang()).toBe(before);
	});

	it("still reconfigures on a mode change", () => {
		const m = mount();
		const rendered = m.lang();

		m.rerender("raw", callbacks());
		expect(m.lang()).not.toBe(rendered);

		m.rerender("rendered", callbacks());
		expect(built).toHaveLength(2);
	});

	it("routes link callbacks to the latest props without a rebuild", () => {
		const m = mount();
		const latest = callbacks();
		m.rerender("rendered", latest);

		const [opts] = built as [LivePreviewOpts];
		opts.openWikiLink("Note");
		expect(opts.resolveWikiLink("Note")).toBe("/w/Note");
		expect(opts.wikiCompletionPaths()).toEqual(["a.md"]);
		opts.openMarkdownLink("https://x");

		expect(latest.openWikiLink).toHaveBeenCalledWith("Note");
		expect(latest.resolveWikiLink).toHaveBeenCalledWith("Note");
		expect(latest.wikiCompletionPaths).toHaveBeenCalled();
		expect(latest.openMarkdownLink).toHaveBeenCalledWith("https://x");
		expect(m.first.openWikiLink).not.toHaveBeenCalled();
		expect(m.first.resolveWikiLink).not.toHaveBeenCalled();
	});
});
