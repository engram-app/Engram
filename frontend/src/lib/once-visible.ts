function scrollParent(el: Element): Element | null {
	for (let node = el.parentElement; node; node = node.parentElement) {
		if (/auto|scroll/u.test(getComputedStyle(node).overflowY)) {
			return node;
		}
	}
	return null;
}

/**
 * Run `fn` once, when `el` comes within `margin` of its scroll container's
 * visible area. Returns a cancel function. Where IntersectionObserver does not
 * exist it runs at once, so nothing that depends on it can be left unrendered.
 *
 * For work that is expensive and only useful on screen, like drawing a Mermaid
 * diagram further down a note: it used to run on open, competing with the
 * editor for the main thread.
 *
 * The observer's root is the nearest scrolling ancestor, not the viewport:
 * rootMargin only grows the root, and a nested scroller clips the element
 * before a viewport margin ever applies.
 */
export function onceVisible(el: Element, fn: () => void, margin = "400px"): () => void {
	if (typeof IntersectionObserver !== "function") {
		fn();
		return () => undefined;
	}
	let done = false;
	let io: IntersectionObserver | null = null;
	const watch = () => {
		if (done) {
			return;
		}
		io = new IntersectionObserver(
			(entries) => {
				if (!done && entries.some((e) => e.isIntersecting)) {
					done = true;
					io?.disconnect();
					fn();
				}
			},
			{ root: scrollParent(el), rootMargin: margin },
		);
		io.observe(el);
	};
	// A CodeMirror widget is handed over before it is attached, when it has no
	// ancestors to search yet.
	let frame = 0;
	if (el.isConnected) {
		watch();
	} else {
		frame = requestAnimationFrame(watch);
	}
	return () => {
		done = true;
		cancelAnimationFrame(frame);
		io?.disconnect();
	};
}
