/**
 * Wrap every dynamic `import()` whose result is read.
 *
 * main.tsx's `vite:preloadError` handler calls preventDefault() and reloads the
 * page. preventDefault() makes the failed import RESOLVE to undefined instead of
 * rejecting, so any code reading `.default` (or a named export, or React.lazy's
 * own `.default` read) throws a TypeError in the moments before the reload
 * lands (Sentry ENGRAM-FRONTEND-3/-6/-B). The page is about to go away, so the
 * harmless move is to wait: an undefined module never settles (lazy stays
 * suspended, init never runs). A real rejection passes through untouched.
 */
export function whenLoaded<T>(load: Promise<T | undefined>): Promise<T> {
	return load.then(
		(module) =>
			module ??
			new Promise<T>(() => {
				// Never settles: the page is reloading.
			}),
	);
}
