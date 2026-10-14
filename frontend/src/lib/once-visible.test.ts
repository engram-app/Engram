import { afterEach, describe, expect, it, vi } from "vitest";
import { onceVisible } from "./once-visible";

interface Entry {
	isIntersecting: boolean;
}
let fire: (entries: Entry[]) => void = () => undefined;
const disconnect = vi.fn();

function stubObserver() {
	vi.stubGlobal(
		"IntersectionObserver",
		class {
			constructor(cb: (entries: Entry[]) => void) {
				fire = cb;
			}
			observe() {}
			disconnect = disconnect;
		},
	);
}

afterEach(() => {
	vi.unstubAllGlobals();
	disconnect.mockClear();
});

describe("onceVisible", () => {
	it("waits until the element nears the viewport, then runs once", () => {
		stubObserver();
		const run = vi.fn();
		onceVisible(document.createElement("div"), run);
		fire([{ isIntersecting: false }]);
		expect(run).not.toHaveBeenCalled();
		fire([{ isIntersecting: true }]);
		fire([{ isIntersecting: true }]);
		expect(run).toHaveBeenCalledOnce();
		expect(disconnect).toHaveBeenCalled();
	});

	it("never runs once cancelled", () => {
		stubObserver();
		const run = vi.fn();
		const cancel = onceVisible(document.createElement("div"), run);
		cancel();
		fire([{ isIntersecting: true }]);
		expect(run).not.toHaveBeenCalled();
		expect(disconnect).toHaveBeenCalled();
	});

	it("runs at once where IntersectionObserver does not exist", () => {
		vi.stubGlobal("IntersectionObserver", undefined);
		const run = vi.fn();
		onceVisible(document.createElement("div"), run);
		expect(run).toHaveBeenCalledOnce();
	});
});
