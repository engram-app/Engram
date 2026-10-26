import { act, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useKeyboardOpen, useVisualViewportBox } from "./use-keyboard-inset";

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

describe("useVisualViewportBox", () => {
	it("is the visual viewport's top and height", () => {
		setLayoutHeight(800);
		stubViewport(500, 40);
		const { result } = renderHook(() => useVisualViewportBox());
		expect(result.current).toEqual({ top: 40, height: 500 });
	});

	it("updates when the viewport resizes", () => {
		setLayoutHeight(800);
		const vv = stubViewport(800);
		const { result } = renderHook(() => useVisualViewportBox());
		vv.height = 500;
		act(() => vv.fire());
		expect(result.current).toEqual({ top: 0, height: 500 });
	});

	// iOS can grow the rows above the keyboard (QuickType, AutoFill, the
	// accessory bar) after the keyboard appears, without firing a resize. So
	// the box keeps sampling for a while after anything keyboard-shaped.
	it("picks up a late change with no event while the keyboard settles", () => {
		vi.useFakeTimers({ toFake: ["requestAnimationFrame", "cancelAnimationFrame", "performance"] });
		try {
			setLayoutHeight(800);
			const vv = stubViewport(800);
			const { result } = renderHook(() => useVisualViewportBox());
			act(() => {
				document.dispatchEvent(new Event("focusin"));
			});
			// The row lands a few frames after the focus, not on the first one.
			act(() => vi.advanceTimersByTime(200));
			vv.height = 460;
			act(() => vi.advanceTimersByTime(100));
			expect(result.current).toEqual({ top: 0, height: 460 });

			// Sampling stops once the keyboard has had time to settle.
			act(() => vi.advanceTimersByTime(1000));
			vv.height = 300;
			act(() => vi.advanceTimersByTime(100));
			expect(result.current).toEqual({ top: 0, height: 460 });
		} finally {
			vi.useRealTimers();
		}
	});

	it("subscribes to both resize and scroll, and unsubscribes on unmount", () => {
		setLayoutHeight(800);
		const vv = stubViewport(800);
		const { unmount } = renderHook(() => useVisualViewportBox());
		expect(vv.addEventListener.mock.calls.map((c) => c[0])).toEqual(["resize", "scroll"]);
		unmount();
		expect(vv.removeEventListener.mock.calls.map((c) => c[0])).toEqual(["resize", "scroll"]);
	});

	// Desktop never shows the toolbar; it should not sample the viewport on
	// every focus change either.
	it("does not subscribe at all when disabled", () => {
		setLayoutHeight(800);
		const vv = stubViewport(800);
		const add = vi.spyOn(document, "addEventListener");
		renderHook(() => useVisualViewportBox(false));
		expect(vv.addEventListener).not.toHaveBeenCalled();
		expect(add.mock.calls.map((c) => c[0])).not.toContain("focusin");
		add.mockRestore();
	});

	// Crossing the desktop breakpoint (iPad split view) re-enables the hook;
	// it must not keep the box it read at mount until the next event.
	it("re-reads the viewport when it is re-enabled", () => {
		setLayoutHeight(800);
		const vv = stubViewport(800);
		const { result, rerender } = renderHook(({ on }) => useVisualViewportBox(on), {
			initialProps: { on: false },
		});
		vv.height = 500;
		rerender({ on: true });
		expect(result.current).toEqual({ top: 0, height: 500 });
	});

	it("leaves a simulated keyboard's worth of room for ?keyboard in dev", () => {
		setLayoutHeight(800);
		stubViewport(800);
		window.history.replaceState(null, "", "/?keyboard");
		const { result } = renderHook(() => useVisualViewportBox());
		expect(result.current.height).toBeLessThan(800);
	});

	it("falls back to the window on a browser with no visualViewport at all", () => {
		setLayoutHeight(800);
		Object.defineProperty(window, "visualViewport", { value: undefined, configurable: true });
		const { result } = renderHook(() => useVisualViewportBox());
		expect(result.current).toEqual({ top: 0, height: 800 });
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
