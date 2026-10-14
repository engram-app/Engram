import { act, renderHook } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import * as Y from "yjs";
import { useDocReady } from "./use-doc-ready";

describe("useDocReady", () => {
	it("is false without a doc", () => {
		const { result } = renderHook(() => useDocReady(null, true));
		expect(result.current).toBe(false);
	});

	it("is ready at once for a note the server says is empty", () => {
		const { result } = renderHook(() => useDocReady(new Y.Doc(), false));
		expect(result.current).toBe(true);
	});

	it("is ready at once when the local copy already has content", () => {
		const doc = new Y.Doc();
		doc.getText("content").insert(0, "cached");
		const { result } = renderHook(() => useDocReady(doc, true));
		expect(result.current).toBe(true);
	});

	it("waits for the server state when the doc opened empty", () => {
		const doc = new Y.Doc();
		const { result } = renderHook(() => useDocReady(doc, true));
		expect(result.current).toBe(false);

		const server = new Y.Doc();
		server.getText("content").insert(0, "from the server");
		act(() => {
			Y.applyUpdate(doc, Y.encodeStateAsUpdate(server));
		});
		expect(result.current).toBe(true);
	});

	it("resets for the next note's doc", () => {
		const full = new Y.Doc();
		full.getText("content").insert(0, "x");
		const { result, rerender } = renderHook(({ doc }) => useDocReady(doc, true), {
			initialProps: { doc: full },
		});
		expect(result.current).toBe(true);
		rerender({ doc: new Y.Doc() });
		expect(result.current).toBe(false);
	});
});
