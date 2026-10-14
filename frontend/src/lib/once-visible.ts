/**
 * Run `fn` once, when `el` comes within `margin` of the viewport. Returns a
 * cancel function. Where IntersectionObserver does not exist it runs at once,
 * so nothing that depends on it can be left unrendered.
 *
 * For work that is expensive and only useful on screen, like drawing a Mermaid
 * diagram further down a note: it used to run on open, competing with the
 * editor for the main thread.
 */
export function onceVisible(el: Element, fn: () => void, margin = "400px"): () => void {
	if (typeof IntersectionObserver !== "function") {
		fn();
		return () => undefined;
	}
	let done = false;
	const io = new IntersectionObserver(
		(entries) => {
			if (!done && entries.some((e) => e.isIntersecting)) {
				done = true;
				io.disconnect();
				fn();
			}
		},
		{ rootMargin: margin },
	);
	io.observe(el);
	return () => {
		done = true;
		io.disconnect();
	};
}
