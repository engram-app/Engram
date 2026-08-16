import { renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useWipeCrdtOnUserChange } from "./use-wipe-crdt-on-user-change";

const wipe = vi.fn(() => Promise.resolve());
vi.mock("../crdt/idb-wipe", () => ({ wipeCrdtIndexedDb: () => wipe() }));

describe("useWipeCrdtOnUserChange", () => {
	afterEach(() => wipe.mockClear());

	it("does not wipe on first mount", () => {
		renderHook(({ id }) => useWipeCrdtOnUserChange(id), { initialProps: { id: "u1" } });
		expect(wipe).not.toHaveBeenCalled();
	});

	it("wipes when the user changes and when the user logs out", () => {
		const { rerender } = renderHook(
			({ id }: { id: string | undefined }) => useWipeCrdtOnUserChange(id),
			{
				initialProps: { id: "u1" as string | undefined },
			},
		);
		rerender({ id: "u2" });
		expect(wipe).toHaveBeenCalledTimes(1);
		rerender({ id: undefined });
		expect(wipe).toHaveBeenCalledTimes(2);
	});

	it("does not wipe on a stable user across rerenders", () => {
		const { rerender } = renderHook(({ id }) => useWipeCrdtOnUserChange(id), {
			initialProps: { id: "u1" },
		});
		rerender({ id: "u1" });
		expect(wipe).not.toHaveBeenCalled();
	});
});

describe("search history is cleared with the same edge", () => {
	// Recent searches are the user's own words ("severance agreement lawyer"),
	// stored in localStorage under a key with no user in it and no expiry. On a
	// shared machine the next person to open the search panel read them.
	it("clears recent searches on sign-out", () => {
		window.localStorage.setItem("engram:recent-searches", JSON.stringify(["severance lawyer"]));

		const { rerender } = renderHook(
			({ id }: { id: string | undefined }) => useWipeCrdtOnUserChange(id),
			{ initialProps: { id: "u1" as string | undefined } },
		);
		rerender({ id: undefined });

		expect(window.localStorage.getItem("engram:recent-searches")).toBeNull();
	});

	// A token refresh does not change the user id, so history must survive it —
	// clearing on every render would look like the feature was broken.
	it("keeps them while the same user stays signed in", () => {
		window.localStorage.setItem("engram:recent-searches", JSON.stringify(["quarterly report"]));

		const { rerender } = renderHook(({ id }) => useWipeCrdtOnUserChange(id), {
			initialProps: { id: "u1" },
		});
		rerender({ id: "u1" });

		expect(window.localStorage.getItem("engram:recent-searches")).toContain("quarterly report");
	});
});
