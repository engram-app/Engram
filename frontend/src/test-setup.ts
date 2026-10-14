import "fake-indexeddb/auto";
import "@testing-library/jest-dom/vitest";

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
