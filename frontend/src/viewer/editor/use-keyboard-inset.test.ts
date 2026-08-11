import { act, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useKeyboardInset, useKeyboardOpen } from "./use-keyboard-inset";

interface FakeViewport {
	height: number;
	width: number;
	offsetTop: number;
	addEventListener: ReturnType<typeof vi.fn>;
	removeEventListener: ReturnType<typeof vi.fn>;
	fire: () => void;
}

const original = {
	visualViewport: window.visualViewport,
	innerHeight: window.innerHeight,
};

/** Stand-in for the API no desktop browser exercises with a real keyboard. */
function stubViewport(height: number, offsetTop = 0, width = 390): FakeViewport {
	const listeners: Array<() => void> = [];
	const vv: FakeViewport = {
		height,
		width,
		offsetTop,
		addEventListener: vi.fn((_evt: string, fn: () => void) => listeners.push(fn)),
		removeEventListener: vi.fn(),
		fire: () => {
			for (const fn of listeners) {
				fn();
			}
		},
	};
	Object.defineProperty(window, "visualViewport", { value: vv, configurable: true });
	return vv;
}

function setLayoutHeight(px: number) {
	Object.defineProperty(window, "innerHeight", { value: px, configurable: true });
}

afterEach(() => {
	Object.defineProperty(window, "visualViewport", {
		value: original.visualViewport,
		configurable: true,
	});
	Object.defineProperty(window, "innerHeight", {
		value: original.innerHeight,
		configurable: true,
	});
	window.history.replaceState(null, "", "/");
});

describe("useKeyboardInset", () => {
	it("reports 0 when the visual viewport fills the window", () => {
		setLayoutHeight(800);
		stubViewport(800);
		const { result } = renderHook(() => useKeyboardInset());
		expect(result.current).toBe(0);
	});

	it("reports the obscured height when the keyboard is up", () => {
		setLayoutHeight(800);
		stubViewport(500);
		const { result } = renderHook(() => useKeyboardInset());
		expect(result.current).toBe(300);
	});

	// Mobile Safari's collapsing address bar moves the visual viewport by
	// ~60-90px on scroll. Counting that as a keyboard flashes the bar on swipe.
	it("ignores an inset too small to be a keyboard", () => {
		setLayoutHeight(800);
		stubViewport(730);
		const { result } = renderHook(() => useKeyboardInset());
		expect(result.current).toBe(0);
	});

	// Panning under the keyboard changes offsetTop without resizing anything;
	// ignoring it leaves the bar floating below its correct position.
	it("accounts for the visual viewport being scrolled", () => {
		setLayoutHeight(800);
		stubViewport(500, 100);
		const { result } = renderHook(() => useKeyboardInset());
		expect(result.current).toBe(200);
	});

	it("updates when the viewport resizes", () => {
		setLayoutHeight(800);
		const vv = stubViewport(800);
		const { result } = renderHook(() => useKeyboardInset());
		expect(result.current).toBe(0);

		vv.height = 500;
		act(() => vv.fire());
		expect(result.current).toBe(300);
	});

	it("subscribes to both resize and scroll, and unsubscribes on unmount", () => {
		setLayoutHeight(800);
		const vv = stubViewport(800);
		const { unmount } = renderHook(() => useKeyboardInset());
		expect(vv.addEventListener.mock.calls.map((c) => c[0])).toEqual(["resize", "scroll"]);
		unmount();
		expect(vv.removeEventListener.mock.calls.map((c) => c[0])).toEqual(["resize", "scroll"]);
	});

	it("returns a simulated inset for ?keyboard so the bar can be driven in dev", () => {
		setLayoutHeight(800);
		stubViewport(800);
		window.history.replaceState(null, "", "/?keyboard");
		const { result } = renderHook(() => useKeyboardInset());
		expect(result.current).toBeGreaterThan(0);
	});

	it("survives a browser with no visualViewport at all", () => {
		setLayoutHeight(800);
		Object.defineProperty(window, "visualViewport", { value: undefined, configurable: true });
		const { result } = renderHook(() => useKeyboardInset());
		expect(result.current).toBe(0);
	});
});

// The hook that decides whether the toolbar is VISIBLE at all, and the one the
// inset cannot stand in for: on browsers that resize the layout viewport the
// inset reads 0 with the keyboard fully open.
//
// Each test uses its own viewport WIDTH. The tallest-height baseline is module
// state keyed by width, so a distinct width gives each test a clean baseline —
// and exercises the rotation reset while doing it.
describe("useKeyboardOpen", () => {
	it("is false at the tallest height it has seen", () => {
		stubViewport(800, 0, 101);
		setLayoutHeight(800);
		expect(renderHook(() => useKeyboardOpen()).result.current).toBe(false);
	});

	it("is true once the viewport shrinks by more than a keyboard's worth", () => {
		const vv = stubViewport(800, 0, 102);
		setLayoutHeight(800);
		const { result } = renderHook(() => useKeyboardOpen());

		vv.height = 500;
		act(() => vv.fire());
		expect(result.current).toBe(true);
	});

	// The case the inset alone gets wrong: the layout viewport shrank too, so
	// innerHeight - vv.height is 0 with the keyboard fully open.
	it("is true even when the layout viewport shrank with it", () => {
		const vv = stubViewport(800, 0, 103);
		setLayoutHeight(800);
		const { result } = renderHook(() => useKeyboardOpen());

		vv.height = 500;
		setLayoutHeight(500);
		act(() => vv.fire());
		expect(result.current).toBe(true);
		expect(renderHook(() => useKeyboardInset()).result.current).toBe(0);
	});

	it("is false again once the viewport grows back", () => {
		const vv = stubViewport(800, 0, 104);
		setLayoutHeight(800);
		const { result } = renderHook(() => useKeyboardOpen());

		vv.height = 500;
		act(() => vv.fire());
		vv.height = 800;
		act(() => vv.fire());
		expect(result.current).toBe(false);
	});

	// A collapsing address bar moves the viewport by ~60-90px on every scroll.
	it("ignores a shrink too small to be a keyboard", () => {
		const vv = stubViewport(800, 0, 105);
		setLayoutHeight(800);
		const { result } = renderHook(() => useKeyboardOpen());

		vv.height = 730;
		act(() => vv.fire());
		expect(result.current).toBe(false);
	});

	// Landscape is legitimately shorter than portrait; without the width key a
	// rotation would read as a permanently open keyboard.
	it("starts a fresh baseline after a rotation rather than comparing orientations", () => {
		const vv = stubViewport(800, 0, 106);
		setLayoutHeight(800);
		const { result, rerender } = renderHook(() => useKeyboardOpen());

		vv.width = 800;
		vv.height = 380;
		act(() => vv.fire());
		rerender();
		expect(result.current).toBe(false);
	});

	it("reports open for ?keyboard so the bar can be driven in dev", () => {
		window.history.replaceState(null, "", "/?keyboard");
		stubViewport(800, 0, 107);
		setLayoutHeight(800);
		expect(renderHook(() => useKeyboardOpen()).result.current).toBe(true);
	});

	it("survives a browser with no visualViewport at all", () => {
		Object.defineProperty(window, "visualViewport", { value: undefined, configurable: true });
		expect(() => renderHook(() => useKeyboardOpen())).not.toThrow();
	});
});
