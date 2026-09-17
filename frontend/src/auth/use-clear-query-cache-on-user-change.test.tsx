import { QueryClient } from "@tanstack/react-query";
import { renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
	clearPendingAuthorization,
	peekPendingAuthorization,
	stashPendingAuthorization,
} from "../oauth/pending-authorization";
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
	clearPendingAuthorization();
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

	// The React Query cache is not the only store that outlives sign-out. A
	// parked OAuth authorization lives in sessionStorage, so without this the
	// next user to sign up in the same tab finishes the wizard and is handed
	// user A's consent screen, carrying A's `state` and `redirect_uri`.
	// Approving there mints a grant on B's account and ships the code to A's
	// redirect.
	it("drops a parked OAuth authorization on sign-out", () => {
		stashPendingAuthorization("?client_id=abc&state=xyz", null, "Claude Code");
		expect(peekPendingAuthorization()).not.toBeNull();

		const { rerender } = mount("user_A");
		rerender({ userId: undefined });

		expect(peekPendingAuthorization()).toBeNull();
	});

	it("drops a parked OAuth authorization on a direct cross-account swap", () => {
		stashPendingAuthorization("?client_id=abc&state=xyz", null, "Claude Code");

		const { rerender } = mount("user_A");
		rerender({ userId: "user_B" });

		expect(peekPendingAuthorization()).toBeNull();
	});
});
