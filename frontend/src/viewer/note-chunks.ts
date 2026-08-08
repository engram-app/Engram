import { type ComponentType, createElement, use } from "react";

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
 * render. So a bare preload leaves the module cached but `lazy` still
 * suspends on first render, paints its fallback, and re-renders — measured at
 * ~760ms of full-pane spinner even with the chunk already fetched (#1317).
 *
 * Here the resolved component lives in a cache the preload fills, so once
 * warm the first render returns it synchronously and no boundary ever shows.
 * Cold, `use()` suspends exactly like `lazy` did — the Suspense boundaries
 * around these stay load-bearing for the cold path and for preload failures.
 */
function preloadable<P extends object>(load: () => Promise<{ default: ComponentType<P> }>) {
	let loaded: ComponentType<P> | null = null;
	let inFlight: Promise<void> | null = null;

	const start = (): Promise<void> => {
		// Retry on a later render if the fetch failed (offline, stale deploy):
		// clearing inFlight is what lets the Suspense path try again instead of
		// re-throwing the same rejected promise forever.
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
		if (!loaded) {
			// Conditional `use` is explicitly allowed, unlike a hook. On an
			// already-resolved promise it returns synchronously without suspending.
			use(start());
		}
		if (!loaded) {
			throw new Error("preloadable: resolved without a component");
		}
		return createElement(loaded as ComponentType<P>, props);
	};

	return { Component, preload: start };
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
