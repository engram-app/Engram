import { QueryClient } from "@tanstack/react-query";
import { renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useClearQueryCacheOnUserChange } from "./use-clear-query-cache-on-user-change";

interface Props {
	userId: string | undefined;
}

let qc: QueryClient;
let clearSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
	qc = new QueryClient();
	clearSpy = vi.spyOn(qc, "clear");
});

afterEach(() => {
	clearSpy.mockRestore();
	qc.clear();
});

function mount(initial: Props["userId"]) {
	return renderHook<void, Props>(({ userId }) => useClearQueryCacheOnUserChange(qc, userId), {
		initialProps: { userId: initial },
	});
}

describe("useClearQueryCacheOnUserChange", () => {
	it("does not clear on initial mount with no signed-in user", () => {
		mount(undefined);
		expect(clearSpy).not.toHaveBeenCalled();
	});

	it("does not clear on first sign-in (undefined -> A)", () => {
		const { rerender } = mount(undefined);
		rerender({ userId: "user_A" });
		expect(clearSpy).not.toHaveBeenCalled();
	});

	it("clears on sign-out (A -> undefined)", () => {
		const { rerender } = mount("user_A");
		rerender({ userId: undefined });
		expect(clearSpy).toHaveBeenCalledTimes(1);
	});

	it("clears on cross-account swap in same tab (A -> B)", () => {
		const { rerender } = mount("user_A");
		rerender({ userId: "user_B" });
		expect(clearSpy).toHaveBeenCalledTimes(1);
	});

	it("does not clear when userId is stable across renders", () => {
		const { rerender } = mount("user_A");
		rerender({ userId: "user_A" });
		rerender({ userId: "user_A" });
		expect(clearSpy).not.toHaveBeenCalled();
	});

	it("clears once per transition (A -> undefined -> B)", () => {
		const { rerender } = mount("user_A");
		rerender({ userId: undefined });
		rerender({ userId: "user_B" });
		expect(clearSpy).toHaveBeenCalledTimes(1);
	});
});
