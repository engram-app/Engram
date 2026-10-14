import { afterEach, describe, expect, it, vi } from "vitest";
import { onceVisible } from "./once-visible";

interface Entry {
	isIntersecting: boolean;
}
let fire: (entries: Entry[]) => void = () => undefined;
let observedRoot: Element | null | undefined;
const disconnect = vi.fn();

function stubObserver() {
	vi.stubGlobal(
		"IntersectionObserver",
		class {
			constructor(cb: (entries: Entry[]) => void, options?: IntersectionObserverInit) {
				fire = cb;
				observedRoot = options?.root as Element | null | undefined;
			}
			observe() {}
			disconnect = disconnect;
		},
	);
}

/** An attached element: a detached one waits a frame for its ancestors. */
function attached(): HTMLElement {
	const el = document.createElement("div");
	document.body.append(el);
	return el;
}

afterEach(() => {
	document.body.replaceChildren();
	vi.unstubAllGlobals();
	disconnect.mockClear();
});

describe("onceVisible", () => {
	it("waits until the element nears the viewport, then runs once", () => {
		stubObserver();
		const run = vi.fn();
		onceVisible(attached(), run);
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
		const cancel = onceVisible(attached(), run);
		cancel();
		fire([{ isIntersecting: true }]);
		expect(run).not.toHaveBeenCalled();
		expect(disconnect).toHaveBeenCalled();
	});

	// rootMargin only grows the ROOT. With the viewport as root, a diagram inside
	// the note's own scroller was clipped by it before the margin applied, so it
	// drew only once already on screen.
	it("observes against the nearest scrolling ancestor", () => {
		stubObserver();
		const scroller = document.createElement("div");
		scroller.style.overflowY = "auto";
		const el = document.createElement("div");
		scroller.append(el);
		document.body.append(scroller);
		onceVisible(el, vi.fn());
		expect(observedRoot).toBe(scroller);
		scroller.remove();
	});

	it("waits for an element to be attached before picking its scroller", async () => {
		stubObserver();
		observedRoot = undefined;
		const scroller = document.createElement("div");
		scroller.style.overflowY = "scroll";
		const el = document.createElement("div");
		const run = vi.fn();
		onceVisible(el, run);
		scroller.append(el);
		document.body.append(scroller);
		await vi.waitFor(() => expect(observedRoot).toBe(scroller));
		fire([{ isIntersecting: true }]);
		expect(run).toHaveBeenCalledOnce();
		scroller.remove();
	});

	it("runs at once where IntersectionObserver does not exist", () => {
		vi.stubGlobal("IntersectionObserver", undefined);
		const run = vi.fn();
		onceVisible(document.createElement("div"), run);
		expect(run).toHaveBeenCalledOnce();
	});
});
