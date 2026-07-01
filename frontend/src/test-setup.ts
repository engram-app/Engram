import "fake-indexeddb/auto";
import "@testing-library/jest-dom";

// happy-dom returns 0 for clientHeight / scrollHeight by default, which
// breaks @tanstack/react-virtual (it computes 0 visible rows). Force
// non-zero defaults on HTMLElement so virtualized components render
// their full list in tests. Production layout/scrolling is unaffected.
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
