import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// The hook caches at module level, so each test imports a fresh copy: one
// page load per test.
async function freshModule() {
	vi.resetModules();
	return import("./use-bootstrap");
}

const fetchMock = vi.fn();

beforeEach(() => {
	fetchMock.mockResolvedValue({
		ok: true,
		json: () => Promise.resolve({ bootstrap_pending: true, registration_mode: "invite_only" }),
	});
	vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
	vi.unstubAllGlobals();
	fetchMock.mockReset();
});

// The first signup closes the claim window. Before this, the cached
// `bootstrap_pending: true` survived until a reload, so signing out bounced
// /sign-in back to /sign-up with the first-run setup token field still showing.
describe("markBootstrapComplete", () => {
	it("updates a page that is already on screen", async () => {
		const { useBootstrap, markBootstrapComplete } = await freshModule();
		const { result } = renderHook(() => useBootstrap());
		await waitFor(() => expect(result.current?.bootstrap_pending).toBe(true));

		act(() => markBootstrapComplete());

		expect(result.current?.bootstrap_pending).toBe(false);
	});

	it("is what the next page sees, with no reload or refetch", async () => {
		const { useBootstrap, markBootstrapComplete } = await freshModule();
		const first = renderHook(() => useBootstrap());
		await waitFor(() => expect(first.result.current?.bootstrap_pending).toBe(true));
		first.unmount();

		markBootstrapComplete();
		const next = renderHook(() => useBootstrap());

		expect(next.result.current).toEqual({
			bootstrap_pending: false,
			registration_mode: "invite_only",
		});
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});

	it("leaves a claimed or non-self-host instance alone", async () => {
		fetchMock.mockResolvedValue({ ok: false, json: () => Promise.resolve({}) });
		const { useBootstrap, markBootstrapComplete } = await freshModule();
		const { result } = renderHook(() => useBootstrap());
		await waitFor(() => expect(result.current).toBeNull());

		act(() => markBootstrapComplete());

		expect(result.current).toBeNull();
	});
});
