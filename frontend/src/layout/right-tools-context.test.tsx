import { act, renderHook } from "@testing-library/react";
import type { ReactNode } from "react";
import { beforeEach, describe, expect, it } from "vitest";
import { RightToolsProvider, useRightTools } from "./right-tools-context";

const wrapper = ({ children }: { children: ReactNode }) => (
	<RightToolsProvider>{children}</RightToolsProvider>
);

const setup = () => renderHook(() => useRightTools(), { wrapper });

beforeEach(() => window.localStorage.clear());

describe("RightToolsProvider", () => {
	it("defaults to the outline, matching the pre-registry behaviour", () => {
		const { result } = setup();
		expect(result.current.activeId).toBe("outline");
	});

	it("keeps the panel collapsed until a contextual tool publishes content", () => {
		const { result } = setup();
		// activeId is "outline" but no page has published one yet (e.g. dashboard).
		expect(result.current.isAvailable("outline")).toBe(false);
		expect(result.current.resolvedId).toBeNull();
	});

	it("resolves a contextual tool once its slot is filled", () => {
		const { result } = setup();
		act(() => result.current.setSlot("outline", <p>toc</p>));
		expect(result.current.isAvailable("outline")).toBe(true);
		expect(result.current.resolvedId).toBe("outline");
	});

	it("treats an always-on tool as available with no slot at all", () => {
		const { result } = setup();
		act(() => result.current.setActive("reference"));
		expect(result.current.isAvailable("reference")).toBe(true);
		expect(result.current.resolvedId).toBe("reference");
	});

	it("retains the chosen tool while it is unavailable so it restores on return", () => {
		const { result } = setup();
		act(() => result.current.setSlot("outline", <p>toc</p>));
		expect(result.current.resolvedId).toBe("outline");

		// Navigate away from the note — the page clears its slot.
		act(() => result.current.setSlot("outline", null));
		expect(result.current.resolvedId).toBeNull();
		expect(result.current.activeId).toBe("outline");

		// Back to a note: the preference was never lost.
		act(() => result.current.setSlot("outline", <p>toc</p>));
		expect(result.current.resolvedId).toBe("outline");
	});

	it("collapses when the active tool is re-activated", () => {
		const { result } = setup();
		act(() => result.current.setActive("reference"));
		act(() => result.current.toggleActive("reference"));
		expect(result.current.activeId).toBeNull();
		expect(result.current.resolvedId).toBeNull();
	});

	it("switches directly between tools without collapsing", () => {
		const { result } = setup();
		act(() => result.current.setActive("reference"));
		act(() => result.current.toggleActive("outline"));
		expect(result.current.activeId).toBe("outline");
	});

	it("ignores a re-publish of the identical node so the outline cannot loop", () => {
		// NotePage republishes the outline on every keystroke; an unguarded
		// setState here would re-render the provider forever.
		const { result } = setup();
		const node = <p>toc</p>;
		act(() => result.current.setSlot("outline", node));
		const first = result.current.slots;
		act(() => result.current.setSlot("outline", node));
		expect(result.current.slots).toBe(first);
	});

	it("persists an explicit collapse and restores it", () => {
		const { result, unmount } = setup();
		act(() => result.current.setActive(null));
		expect(window.localStorage.getItem("engram:right-tool")).toBe("");
		unmount();

		const second = setup();
		expect(second.result.current.activeId).toBeNull();
	});

	it("persists the chosen tool across mounts", () => {
		const { result, unmount } = setup();
		act(() => result.current.setActive("reference"));
		unmount();

		const second = setup();
		expect(second.result.current.activeId).toBe("reference");
	});

	it("falls back to the outline for a stale id from an older build", () => {
		window.localStorage.setItem("engram:right-tool", "does-not-exist");
		const { result } = setup();
		expect(result.current.activeId).toBe("outline");
	});

	it("throws when used outside the provider", () => {
		expect(() => renderHook(() => useRightTools())).toThrow(/RightToolsProvider/u);
	});
});
