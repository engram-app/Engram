// One mermaid instance, shared by Reading mode's <MermaidBlock> and the
// editor's live-preview decoration. Both need the same lazy import, the same
// per-render theme handling and the same lazy draw (drawMermaid), and two
// copies of that would be two chances to drift.

import { onceVisible } from "@/lib/once-visible";

// A diagram draws late (lazy chunk, drawn when scrolled near), so its box grew
// from empty to full height after the note was on screen and shoved every line
// below it down. The height it last drew at is kept here, across reloads, so
// the box is reserved before the SVG arrives. A first-ever view still grows.
const HEIGHTS_KEY = "engram.mermaidHeights";
const MAX_HEIGHTS = 200;

/** Where the diagram is drawn: the two surfaces pad it differently. */
type Surface = "editor" | "reading";

// ponytail: polynomial string hash plus length. A collision only reserves the
// wrong height for one diagram, which the real draw then corrects.
function heightKey(surface: Surface, code: string): string {
	let h = 0;
	for (let i = 0; i < code.length; i++) {
		h = (h * 31 + code.charCodeAt(i)) % 2_147_483_647;
	}
	return `${surface}:${code.length}:${h}`;
}

// Parsed once per page load: the editor asks on every heightmap estimate.
let heightsCache: Record<string, number> | null = null;

// Storage failures (private mode, quota, a hand-edited value) are swallowed on
// purpose: this is a layout hint, and losing it only brings the jump back.
function readHeights(): Record<string, number> {
	heightsCache ??= parseHeights();
	return heightsCache;
}

function parseHeights(): Record<string, number> {
	try {
		const parsed: unknown = JSON.parse(localStorage.getItem(HEIGHTS_KEY) ?? "{}");
		const heights: Record<string, number> = {};
		if (parsed && typeof parsed === "object") {
			for (const [key, value] of Object.entries(parsed)) {
				if (typeof value === "number") {
					heights[key] = value;
				}
			}
		}
		return heights;
	} catch {
		return {};
	}
}

let mermaidPromise: Promise<typeof import("mermaid").default> | null = null;

// Mermaid 12 defaults `layout` to "elk", which downloads a 1.4 MB layout engine
// for every diagram. Obsidian draws with dagre, Mermaid's classic layout, so
// diagrams look the same in both. A diagram can still opt into ELK through its
// own config; mermaid then loads it on demand.
const BASE_CONFIG = { startOnLoad: false, securityLevel: "strict", layout: "dagre" } as const;

// Theme is NOT set here. Mermaid bakes the palette into the SVG at render time,
// so a module-level `theme: "default"` drew dark-on-transparent diagrams that
// were unreadable in dark mode. `initialize` is idempotent and merges, so
// renderMermaid re-applies the palette before each render instead.
function loadMermaid() {
	if (!mermaidPromise) {
		mermaidPromise = import("mermaid")
			.then((m) => {
				m.default.initialize(BASE_CONFIG);
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

// Mermaid measures each diagram in a scratch div it appends to whatever it is
// given, <body> by default. On <body> that div overflowed the page for the
// length of a render, so the window scrollbar flashed in and out and narrowed
// the note. This box keeps it in layout (mermaid needs real text metrics) but
// clipped to nothing and out of the page's scrollable area.
let scratch: HTMLElement | null = null;

function scratchSpace(): HTMLElement {
	if (!scratch?.isConnected) {
		scratch = document.createElement("div");
		scratch.setAttribute("aria-hidden", "true");
		Object.assign(scratch.style, {
			position: "fixed",
			top: "0",
			left: "0",
			width: "100vw",
			height: "0px",
			overflow: "hidden",
			visibility: "hidden",
			pointerEvents: "none",
		});
		document.body.append(scratch);
	}
	return scratch;
}

let idCounter = 0;

/** Mermaid needs a unique DOM id per render; it uses it to key its own scratch node. */
function nextMermaidId(): string {
	idCounter += 1;
	return `mermaid-${idCounter}`;
}

/**
 * Render `code` to SVG markup. `dark` re-draws rather than restyles, because
 * the palette is baked into the output.
 */
export function renderMermaid(code: string, dark: boolean): Promise<string> {
	const result = queue.then(async () => {
		const mermaid = await loadMermaid();
		mermaid.initialize({ ...BASE_CONFIG, theme: dark ? "dark" : "default" });
		const { svg } = await mermaid.render(nextMermaidId(), code, scratchSpace());
		return svg;
	});
	// The queue must survive a bad diagram: chaining the rejection would fail
	// every subsequent render with the FIRST diagram's parse error.
	queue = result.catch(() => undefined);
	return result;
}

export function rememberedMermaidHeight(surface: Surface, code: string): number | undefined {
	const h = readHeights()[heightKey(surface, code)];
	return typeof h === "number" && h > 0 ? h : undefined;
}

export function rememberMermaidHeight(surface: Surface, code: string, height: number): void {
	const heights = readHeights();
	const key = heightKey(surface, code);
	// Re-inserted so key order is recency order; the oldest go first.
	delete heights[key];
	heights[key] = Math.round(height);
	const keys = Object.keys(heights);
	for (const old of keys.slice(0, Math.max(0, keys.length - MAX_HEIGHTS))) {
		delete heights[old];
	}
	try {
		localStorage.setItem(HEIGHTS_KEY, JSON.stringify(heights));
	} catch {
		// See readHeights.
	}
}

/**
 * Draw `code` into `el` once it is scrolled near (see lib/once-visible.ts):
 * a diagram further down a note cost ~0.6s of main thread under mobile
 * throttling while the editor was still starting. Until the SVG lands, `el`
 * holds the height this diagram last drew at, so the content below it does
 * not jump. Returns a cancel function; a cancelled draw never touches `el`.
 */
export function drawMermaid(
	el: HTMLElement,
	surface: Surface,
	code: string,
	dark: boolean,
	on: { drawn: () => void; failed: (err: unknown) => void },
): () => void {
	const reserved = rememberedMermaidHeight(surface, code);
	if (reserved) {
		el.style.minHeight = `${reserved}px`;
	}
	let cancelled = false;
	const stop = onceVisible(el, () => {
		renderMermaid(code, dark).then(
			(svg) => {
				if (cancelled) {
					return;
				}
				el.innerHTML = svg;
				el.style.minHeight = "";
				rememberMermaidHeight(surface, code, el.getBoundingClientRect().height);
				on.drawn();
			},
			(err: unknown) => {
				if (cancelled) {
					return;
				}
				el.style.minHeight = "";
				on.failed(err);
			},
		);
	});
	return () => {
		cancelled = true;
		stop();
	};
}
