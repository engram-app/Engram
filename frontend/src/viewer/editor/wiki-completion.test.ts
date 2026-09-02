import {
	CompletionContext,
	type CompletionResult,
	type CompletionSource,
} from "@codemirror/autocomplete";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import { livePreviewExtensions } from "./live-preview";
import {
	MD_LINK_TRIGGER_RE,
	mdLinkCompletionSource,
	WIKI_TRIGGER_RE,
	wikiCompletionCandidates,
	wikiCompletionSource,
} from "./wiki-completion";

const paths = ["Deep/Sub/Alpha.md", "Alphabet.md", "notes/beta.md", "Gamma Ray.md"];

describe("wikiCompletionCandidates", () => {
	test("basename prefix matches rank before substring matches", () => {
		const labels = wikiCompletionCandidates("alp", paths).map((c) => c.label);
		expect(labels).toEqual(["Alpha", "Alphabet"]);
	});

	test("path substring matches included after basename matches", () => {
		const labels = wikiCompletionCandidates("notes", paths).map((c) => c.label);
		expect(labels).toEqual(["beta"]);
	});

	test("empty query lists everything capped", () => {
		expect(wikiCompletionCandidates("", paths)).toHaveLength(4);
	});

	test("case-insensitive", () => {
		expect(wikiCompletionCandidates("GAMMA", paths)[0]?.label).toBe("Gamma Ray");
	});

	test("detail is the folder path minus filename, empty at root", () => {
		expect(wikiCompletionCandidates("alpha", paths)[0]?.detail).toBe("Deep/Sub");
		expect(wikiCompletionCandidates("gamma", paths)[0]?.detail).toBe("");
	});

	test("caps at 50 results", () => {
		const many = Array.from({ length: 80 }, (_, i) => `note-${i}.md`);
		expect(wikiCompletionCandidates("note", many)).toHaveLength(50);
	});

	test("carries the full path, which the markdown-link apply inserts", () => {
		expect(wikiCompletionCandidates("alpha", paths)[0]?.path).toBe("Deep/Sub/Alpha.md");
	});
});

describe("MD_LINK_TRIGGER_RE", () => {
	test("matches an open ]( with a partial target", () => {
		expect(MD_LINK_TRIGGER_RE.test("see [text](Al")).toBe(true);
	});

	test("matches a target containing spaces", () => {
		// Note names routinely contain spaces; stopping at the first one would
		// close the popup halfway through "Gamma Ray".
		expect(MD_LINK_TRIGGER_RE.test("see [text](Gamma Ra")).toBe(true);
	});

	test("does not match after a closed link", () => {
		expect(MD_LINK_TRIGGER_RE.test("see [text](done) Al")).toBe(false);
	});

	test("does not match a bare paren", () => {
		expect(MD_LINK_TRIGGER_RE.test("see (Al")).toBe(false);
	});

	test("does not match a wikilink", () => {
		expect(MD_LINK_TRIGGER_RE.test("see [[Al")).toBe(false);
	});
});

describe("WIKI_TRIGGER_RE", () => {
	test("matches an open [[ with a partial target", () => {
		expect(WIKI_TRIGGER_RE.test("see [[Al")).toBe(true);
	});

	test("does not match a single bracket", () => {
		expect(WIKI_TRIGGER_RE.test("see [Al")).toBe(false);
	});

	test("does not match after a closed link", () => {
		expect(WIKI_TRIGGER_RE.test("[[done]] Al")).toBe(false);
	});

	test("does not match inside an alias segment", () => {
		expect(WIKI_TRIGGER_RE.test("[[a|b")).toBe(false);
	});
});

describe("wikiCompletionSource", () => {
	function contextAt(doc: string, pos: number): CompletionContext {
		const state = EditorState.create({ doc });
		return new CompletionContext(state, pos, false);
	}

	// wikiCompletionSource never does async work, but its declared type is the
	// general CompletionSource (which allows a Promise); narrow it once here
	// instead of at every call site below.
	function callSource(source: CompletionSource, ctx: CompletionContext): CompletionResult | null {
		const result = source(ctx);
		if (result instanceof Promise) {
			throw new Error("expected a synchronous result");
		}
		return result;
	}

	test("returns null when the trigger doesn't match", () => {
		const source = wikiCompletionSource(() => paths);
		const ctx = contextAt("no link here", 5);
		expect(callSource(source, ctx)).toBeNull();
	});

	test("returns candidates sourced from getPaths, anchored after [[", () => {
		const source = wikiCompletionSource(() => paths);
		const doc = "see [[Al";
		const ctx = contextAt(doc, doc.length);
		const result = callSource(source, ctx);
		expect(result).not.toBeNull();
		expect(result?.from).toBe(doc.indexOf("[[") + 2);
		expect(result?.options.map((o) => o.label)).toEqual(["Alpha", "Alphabet"]);
	});

	test("apply inserts target + closing braces when none follow the cursor", () => {
		const source = wikiCompletionSource(() => paths);
		const doc = "see [[Al";
		const ctx = contextAt(doc, doc.length);
		const result = callSource(source, ctx);
		const option = result?.options[0];
		expect(option).toBeDefined();
		if (!option || typeof option.apply !== "function") {
			throw new Error("expected a function apply");
		}
		const view = new EditorView({ state: EditorState.create({ doc }) });
		option.apply(view, option, result?.from as number, doc.length);
		expect(view.state.doc.toString()).toBe("see [[Alpha]]");
		expect(view.state.selection.main.head).toBe("see [[Alpha".length);
		view.destroy();
	});

	test("apply inserts only the target when ]] already follows the cursor", () => {
		const source = wikiCompletionSource(() => paths);
		const doc = "see [[Al]]";
		const cursorPos = doc.indexOf("Al") + "Al".length;
		const ctx = contextAt(doc, cursorPos);
		const result = callSource(source, ctx);
		const option = result?.options[0];
		expect(option).toBeDefined();
		if (!option || typeof option.apply !== "function") {
			throw new Error("expected a function apply");
		}
		const view = new EditorView({ state: EditorState.create({ doc }) });
		option.apply(view, option, result?.from as number, cursorPos);
		expect(view.state.doc.toString()).toBe("see [[Alpha]]");
		view.destroy();
	});

	test("apply inserts only the target when a |alias]] tail already follows the cursor", () => {
		const source = wikiCompletionSource(() => paths);
		const doc = "see [[Al|alias]]";
		const cursorPos = doc.indexOf("Al") + "Al".length;
		const ctx = contextAt(doc, cursorPos);
		const result = callSource(source, ctx);
		const option = result?.options[0];
		expect(option).toBeDefined();
		if (!option || typeof option.apply !== "function") {
			throw new Error("expected a function apply");
		}
		const view = new EditorView({ state: EditorState.create({ doc }) });
		option.apply(view, option, result?.from as number, cursorPos);
		// Must NOT double-insert "]]" -- the alias/close tail is already there.
		expect(view.state.doc.toString()).toBe("see [[Alpha|alias]]");
		expect(view.state.selection.main.head).toBe("see [[Alpha".length);
		view.destroy();
	});

	test("apply inserts only the target when a #heading]] tail already follows the cursor", () => {
		const source = wikiCompletionSource(() => paths);
		const doc = "see [[Al#heading]]";
		const cursorPos = doc.indexOf("Al") + "Al".length;
		const ctx = contextAt(doc, cursorPos);
		const result = callSource(source, ctx);
		const option = result?.options[0];
		expect(option).toBeDefined();
		if (!option || typeof option.apply !== "function") {
			throw new Error("expected a function apply");
		}
		const view = new EditorView({ state: EditorState.create({ doc }) });
		option.apply(view, option, result?.from as number, cursorPos);
		expect(view.state.doc.toString()).toBe("see [[Alpha#heading]]");
		expect(view.state.selection.main.head).toBe("see [[Alpha".length);
		view.destroy();
	});
});

describe("mdLinkCompletionSource", () => {
	function contextAt(doc: string, pos: number): CompletionContext {
		return new CompletionContext(EditorState.create({ doc }), pos, false);
	}

	function callSource(source: CompletionSource, ctx: CompletionContext): CompletionResult | null {
		const result = source(ctx);
		if (result instanceof Promise) {
			throw new Error("expected a synchronous result");
		}
		return result;
	}

	function applyFirst(doc: string, cursor: number): string {
		const source = mdLinkCompletionSource(() => paths);
		const result = callSource(source, contextAt(doc, cursor));
		const option = result?.options[0];
		if (!option || typeof option.apply !== "function") {
			throw new Error("expected a function apply");
		}
		const view = new EditorView({ state: EditorState.create({ doc }) });
		option.apply(view, option, result?.from as number, cursor);
		const text = view.state.doc.toString();
		view.destroy();
		return text;
	}

	test("returns null outside a markdown-link target", () => {
		const source = mdLinkCompletionSource(() => paths);
		expect(callSource(source, contextAt("no link here", 5))).toBeNull();
	});

	test("anchors candidates after the ](", () => {
		const source = mdLinkCompletionSource(() => paths);
		const doc = "see [text](Al";
		const result = callSource(source, contextAt(doc, doc.length));
		expect(result?.from).toBe(doc.indexOf("](") + 2);
		expect(result?.options.map((o) => o.label)).toEqual(["Alpha", "Alphabet"]);
	});

	// The FULL path, not the basename the row displays: a markdown destination
	// is resolved by resolveWikiTarget's exact-path branch, so the path is
	// unambiguous where a basename shared by two notes is not.
	test("inserts the full path and closes the paren", () => {
		expect(applyFirst("see [text](Al", "see [text](Al".length)).toBe(
			"see [text](Deep/Sub/Alpha.md)",
		);
	});

	test("does not double the paren when one already follows", () => {
		const doc = "see [text](Al)";
		expect(applyFirst(doc, doc.indexOf("Al") + 2)).toBe("see [text](Deep/Sub/Alpha.md)");
	});

	// A raw space is not a legal markdown destination — CommonMark would stop
	// parsing the link at it — so the inserted path has to be encoded.
	test("percent-encodes spaces in the path", () => {
		const doc = "see [text](Gamma";
		expect(applyFirst(doc, doc.length)).toBe("see [text](Gamma%20Ray.md)");
	});
});

describe("wikiCompletionSource composed into livePreviewExtensions", () => {
	let view: EditorView;
	afterEach(() => view?.destroy());

	test("does not throw when composed with the full live-preview extension set", () => {
		const ext = livePreviewExtensions({
			resolveWikiLink: (n) => `/w/wiki/${n}`,
			openWikiLink: () => {},
			wikiCompletionPaths: () => paths,
			openMarkdownLink: () => false,
		});
		expect(() => {
			view = new EditorView({
				state: EditorState.create({ doc: "hello", extensions: ext }),
				parent: document.body,
			});
		}).not.toThrow();
	});
});
