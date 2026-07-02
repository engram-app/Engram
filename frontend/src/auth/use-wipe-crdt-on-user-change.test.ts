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
