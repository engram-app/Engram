import { onceVisible } from "@/lib/once-visible";
import { whenLoaded } from "@/lib/when-loaded";
// One diagram renderer, shared by Reading mode's <MermaidBlock> and the
// editor's live-preview decoration. Both need the same lazy import, the same
// render options and the same lazy draw (drawMermaid), and two copies of that
// would be two chances to drift.
import "./mermaid-theme.css";

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

let pelePromise: Promise<typeof import("pele/lazy")> | null = null;

// Pele (pele.run, by the Obsidian team) replaced mermaid.js: zero deps, a
// sync and stateless render, and colours from `--pele-*` CSS variables
// (mermaid-theme.css), so a light/dark flip recolours a drawn diagram with no
// re-render. Gone with mermaid: the serialized render queue (its global
// `initialize` raced), the per-render theme, the scratch measuring div and the
// dagre-vs-ELK config. `pele/lazy` keeps it a lazy chunk and loads each
// diagram type on first use.
function loadPele() {
	if (!pelePromise) {
		pelePromise = whenLoaded(import("pele/lazy")).catch((err) => {
			// Drop the rejected promise so the NEXT diagram retries the import.
			// Cached, one transient failure (a stale chunk 404 after a deploy while
			// the tab is open, an offline blip) latched permanently and every
			// diagram in the session rendered the same error.
			pelePromise = null;
			throw err;
		});
	}
	return pelePromise;
}

let idCounter = 0;

/**
 * Render `code` to SVG markup.
 *
 * Diagrams are note content, so the options are ours alone (Pele's security
 * page: never let the diagram supply them). Pele emits no scripts, handlers or
 * HTML labels, always blocks javascript:/data:/vbscript: links and caps source
 * and output size. On top of that: no remote images (a diagram must not make
 * the reader's browser fetch a URL), links never pass a referrer, and no
 * `icons`/`math` hooks, the two inputs Pele inserts unfiltered.
 */
export async function renderMermaid(code: string, fontFamily?: string): Promise<string> {
	const { renderAsync } = await loadPele();
	idCounter += 1;
	const { svg } = await renderAsync(code, {
		images: false,
		linkRel: "noopener noreferrer nofollow",
		idPrefix: `pele-${idCounter}-`,
		...(fontFamily ? { fontFamily } : {}),
	});
	return svg;
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
	on: { drawn: () => void; failed: (err: unknown) => void },
): () => void {
	const reserved = rememberedMermaidHeight(surface, code);
	if (reserved) {
		el.style.minHeight = `${reserved}px`;
	}
	let cancelled = false;
	const stop = onceVisible(el, () => {
		// Pele measures labels to size nodes, so it needs the font they draw in.
		renderMermaid(code, getComputedStyle(el).fontFamily).then(
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
