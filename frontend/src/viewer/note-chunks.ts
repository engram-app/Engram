import { type ComponentType, createElement, lazy, useState } from "react";

/**
 * The lazy chunks on the path to reading a note, and one call to warm them.
 *
 * Opening the first note walks THREE lazy boundaries in series — the route's
 * `VaultItemPage`, the `NotePage` it resolves to, and the `NoteEditor` inside
 * that. Two of them fall back to a full-pane spinner, so the measured
 * first-open sequence was: empty state -> loading circle -> chrome -> content,
 * ~2.6s end to end, of which ~1358ms was the editor chunk alone (#1317).
 *
 * They stay split — that split is what keeps the main bundle off 1.78 MB (see
 * router.tsx). Splitting decides what the browser must PARSE up front;
 * preloading decides when it FETCHES. Warming these once the shell is painted
 * keeps the small initial bundle and spends otherwise-idle network on the
 * thing the user is about to do anyway.
 */

/**
 * `React.lazy`, except a preload actually prevents the fallback.
 *
 * This is not the same as calling `import()` next to a `React.lazy` with the
 * same specifier. `lazy` tracks its own status independently of the ES module
 * registry: it only records the component after IT invokes the factory during
 * render, so a bare preload leaves the module cached and `lazy` still suspends
 * on first render, paints its fallback and re-renders.
 *
 * How large that window is depends on the environment — the ~760ms of
 * full-pane spinner that motivated this was measured against the Vite DEV
 * server, where a chunk is a module graph served request-per-file; a
 * production build with the chunk already evaluated should be far closer to a
 * single tick. What this buys unconditionally is the GUARANTEE: a warmed
 * component renders synchronously, so no fallback can appear at all, in any
 * environment. That property is pinned by note-chunks.test.tsx.
 *
 * Cold, it IS `React.lazy` — the Suspense boundaries around these stay
 * load-bearing for the cold path and for preload failures.
 */
function preloadable<P extends object>(load: () => Promise<{ default: ComponentType<P> }>) {
	let loaded: ComponentType<P> | null = null;
	let inFlight: Promise<void> | null = null;

	// The cold path is plain React.lazy — no reason to reimplement suspense.
	const Lazy = lazy(async () => {
		const m = await load();
		loaded = m.default;
		return m;
	});

	const preload = (): Promise<void> => {
		// Clearing inFlight on failure lets a later render call load() again
		// rather than re-throwing one dead promise forever. Be honest about the
		// ceiling: if the FETCH itself failed, the browser caches that failure in
		// the module map and every retry rejects instantly from cache — only a
		// document reload clears it, which is what main.tsx's stale-deploy
		// self-heal is for. This retry only recovers the cases that fail after
		// the module resolved.
		inFlight ??= load()
			.then((m) => {
				loaded = m.default;
			})
			.catch((err) => {
				inFlight = null;
				throw err;
			});
		return inFlight;
	};

	const Component = (props: P) => {
		// Decided ONCE per mount. Reading `loaded` on every render would swap the
		// element type from Lazy to the concrete component the moment a preload
		// landed mid-life, and React remounts the whole subtree on an element-type
		// change — which for NotePage means tearing down a live editor.
		const [Impl] = useState<ComponentType<P>>(() => loaded ?? (Lazy as ComponentType<P>));
		return createElement(Impl, props);
	};

	return { Component, preload };
}

const vaultItemPage = preloadable(() => import("./vault-item-page"));
const notePage = preloadable(() => import("./note-page"));
const noteEditor = preloadable(() => import("./note-editor"));

export const VaultItemPage = vaultItemPage.Component;
export const NotePage = notePage.Component;
export const NoteEditor = noteEditor.Component;

/**
 * Fetch and resolve the note-viewing chunks ahead of the first open.
 *
 * Fire-and-forget by design: a failed preload is not worth surfacing, because
 * each component retries on render and reports the failure at its Suspense
 * boundary, where there is an error boundary to catch it. Swallowing here
 * only prevents an unhandled rejection.
 */
export function preloadNoteChunks(): void {
	vaultItemPage.preload().catch(() => undefined);
	notePage.preload().catch(() => undefined);
	noteEditor.preload().catch(() => undefined);
}
