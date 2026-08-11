import { act, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useKeyboardInset } from "./use-keyboard-inset";

interface FakeViewport {
	height: number;
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
function stubViewport(height: number, offsetTop = 0): FakeViewport {
	const listeners: Array<() => void> = [];
	const vv: FakeViewport = {
		height,
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
