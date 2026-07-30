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
		mermaidPromise = import("mermaid").then((m) => {
			m.default.initialize({ startOnLoad: false, securityLevel: "strict" });
			return m.default;
		});
	}
	return mermaidPromise;
}

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
export async function renderMermaid(id: string, code: string, dark: boolean): Promise<string> {
	const mermaid = await loadMermaid();
	mermaid.initialize({
		startOnLoad: false,
		securityLevel: "strict",
		theme: dark ? "dark" : "default",
	});
	const { svg } = await mermaid.render(id, code);
	return svg;
}
