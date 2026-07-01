import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { useDebouncedValue } from "./use-debounced-value";

describe("useDebouncedValue", () => {
	beforeEach(() => {
		vi.useFakeTimers();
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	it("returns the initial value immediately", () => {
		const { result } = renderHook(() => useDebouncedValue("a", 300));
		expect(result.current).toBe("a");
	});

	it("adopts only the latest value, only after the delay elapses", () => {
		const { result, rerender } = renderHook(({ v }) => useDebouncedValue(v, 300), {
			initialProps: { v: "a" },
		});

		rerender({ v: "ab" });
		rerender({ v: "abc" });
		expect(result.current).toBe("a");

		act(() => {
			vi.advanceTimersByTime(299);
		});
		expect(result.current).toBe("a");

		act(() => {
			vi.advanceTimersByTime(1);
		});
		expect(result.current).toBe("abc");
	});

	it("restarts the timer on every change (trailing debounce)", () => {
		const { result, rerender } = renderHook(({ v }) => useDebouncedValue(v, 300), {
			initialProps: { v: "a" },
		});

		act(() => {
			vi.advanceTimersByTime(200);
		});
		rerender({ v: "ab" });
		act(() => {
			vi.advanceTimersByTime(200);
		});
		// 400ms since mount but only 200ms since last change — still 'a'
		expect(result.current).toBe("a");

		act(() => {
			vi.advanceTimersByTime(100);
		});
		expect(result.current).toBe("ab");
	});
});
