import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as Y from "yjs";
import { useLiveContent } from "./use-live-content";

describe("useLiveContent", () => {
	beforeEach(() => vi.useFakeTimers());
	afterEach(() => vi.useRealTimers());

	it("returns fallback when ytext is null", () => {
		const { result } = renderHook(() => useLiveContent(null, "rest content"));
		expect(result.current).toBe("rest content");
	});

	it("returns the ytext content and follows edits (debounced)", () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		ytext.insert(0, "hello");
		const { result } = renderHook(() => useLiveContent(ytext, "rest"));
		expect(result.current).toBe("hello");
		act(() => {
			ytext.insert(5, " world");
		});
		expect(result.current).toBe("hello"); // debounce window still open
		act(() => {
			vi.advanceTimersByTime(300);
		});
		expect(result.current).toBe("hello world");
	});

	it("follows remote-origin edits too", () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		const { result } = renderHook(() => useLiveContent(ytext, "rest"));
		act(() => {
			// simulate a remote frame: transact with a foreign origin
			doc.transact(() => ytext.insert(0, "remote edit"), "remote");
			vi.advanceTimersByTime(300);
		});
		expect(result.current).toBe("remote edit");
	});

	it("unsubscribes on unmount", () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		const { unmount } = renderHook(() => useLiveContent(ytext, "rest"));
		unmount();
		expect(() => {
			ytext.insert(0, "x");
			vi.advanceTimersByTime(300);
		}).not.toThrow();
	});
});
