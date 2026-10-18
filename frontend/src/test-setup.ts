import "fake-indexeddb/auto";
import "@testing-library/jest-dom/vitest";
import { configure } from "@testing-library/react";

// findBy*/waitFor give up after 1s by default, below vitest's 5s test
// timeout. A first lazy-chunk import or a WebCrypto digest can take longer
// than 1s on a loaded machine, which failed tests that were correct. Wait as
// long as the test itself may run.
configure({ asyncUtilTimeout: 5000 });

// happy-dom returns 0 for clientHeight / scrollHeight by default, which
// breaks @tanstack/react-virtual (it computes 0 visible rows). Force
// non-zero defaults on HTMLElement so virtualized components render
// their full list in tests. Production layout/scrolling is unaffected.
// Guarded: worker/index.test.ts opts into `@vitest-environment node` (real
// fetch/Request/Headers, unlike happy-dom, which silently drops forbidden
// "Sec-*" request headers) and has no HTMLElement at all.
if (typeof HTMLElement !== "undefined") {
	Object.defineProperty(HTMLElement.prototype, "clientHeight", {
		configurable: true,
		get: () => 600,
	});
	Object.defineProperty(HTMLElement.prototype, "clientWidth", {
		configurable: true,
		get: () => 800,
	});
	Object.defineProperty(HTMLElement.prototype, "scrollHeight", {
		configurable: true,
		get: () => 600,
	});
	Object.defineProperty(HTMLElement.prototype, "offsetHeight", {
		configurable: true,
		get: () => 600,
	});
	Object.defineProperty(HTMLElement.prototype, "offsetWidth", {
		configurable: true,
		get: () => 800,
	});
}

// happy-dom has no layout, so its IntersectionObserver never reports anything
// and work deferred until visible (lib/once-visible.ts) would never run. Treat
// every observed element as on screen, consistent with the faked sizes above.
class OnScreenObserver implements IntersectionObserver {
	readonly root = null;
	readonly rootMargin = "";
	readonly scrollMargin = "";
	readonly thresholds = [];
	private readonly callback: IntersectionObserverCallback;
	constructor(callback: IntersectionObserverCallback) {
		this.callback = callback;
	}
	observe(target: Element) {
		const entry = { isIntersecting: true, target } as IntersectionObserverEntry;
		this.callback([entry], this);
	}
	unobserve() {}
	disconnect() {}
	takeRecords() {
		return [];
	}
}
globalThis.IntersectionObserver = OnScreenObserver;

// The Selection API spec queues `selectionchange` as a task; happy-dom
// dispatches it synchronously from inside Selection.collapse(). CodeMirror
// collapses the DOM selection while EditorView.update is running, and since
// @codemirror/view 6.43.14 a seen selection change always re-renders, so the
// sync event re-enters update() and throws "Calls to EditorView.update are
// not allowed while an update is in progress". Defer it like a browser does.
if (typeof document !== "undefined") {
	const dispatch = document.dispatchEvent.bind(document);
	document.dispatchEvent = (event: Event) => {
		if (event.type !== "selectionchange") {
			return dispatch(event);
		}
		setTimeout(() => dispatch(event));
		return true;
	};
}
