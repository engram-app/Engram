// One mermaid instance, shared by Reading mode's <MermaidBlock> and the
// editor's live-preview decoration. Both need the same lazy import and the same
// per-render theme handling, and two copies of that would be two chances to
// drift.

let mermaidPromise: Promise<typeof import("mermaid").default> | null = null;

// Theme is NOT set here. Mermaid bakes the palette into the SVG at render time,
// so a module-level `theme: "default"` drew dark-on-transparent diagrams that
// were unreadable in dark mode. `initialize` is idempotent and merges, so
// renderMermaid re-applies the palette before each render instead.
function loadMermaid() {
	if (!mermaidPromise) {
		mermaidPromise = import("mermaid")
			.then((m) => {
				m.default.initialize({ startOnLoad: false, securityLevel: "strict" });
				return m.default;
			})
			.catch((err) => {
				// Drop the rejected promise so the NEXT diagram retries the import.
				// Cached, one transient failure — a stale chunk 404 after a deploy
				// while the tab is open, an offline blip — latched permanently and
				// every mermaid block in the session, in both panes, rendered the
				// same error. Nothing distinguished that from "your diagram is
				// wrong", because both surface through the same message.
				mermaidPromise = null;
				throw err;
			});
	}
	return mermaidPromise;
}

// Renders run one at a time. `initialize` mutates ONE global config, so two
// concurrent calls could interleave as init(A) → init(B) → render(A), drawing A
// with B's palette. Reading mode and the editor's live preview each render the
// same note, and during a theme flip they briefly disagree about `dark` — which
// is exactly the window that produces a diagram in the wrong palette.
let queue: Promise<unknown> = Promise.resolve();

let idCounter = 0;

/** Mermaid needs a unique DOM id per render; it uses it to key its own scratch node. */
export function nextMermaidId(): string {
	idCounter += 1;
	return `mermaid-${idCounter}`;
}

/**
 * Render `code` to SVG markup. `dark` re-draws rather than restyles, because
 * the palette is baked into the output.
 */
export function renderMermaid(id: string, code: string, dark: boolean): Promise<string> {
	const result = queue.then(async () => {
		const mermaid = await loadMermaid();
		mermaid.initialize({
			startOnLoad: false,
			securityLevel: "strict",
			theme: dark ? "dark" : "default",
		});
		const { svg } = await mermaid.render(id, code);
		return svg;
	});
	// The queue must survive a bad diagram: chaining the rejection would fail
	// every subsequent render with the FIRST diagram's parse error.
	queue = result.catch(() => undefined);
	return result;
}
