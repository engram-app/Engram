import { act, renderHook } from "@testing-library/react";
import React from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { track } from "../analytics/track";
import { type AuthAdapter, AuthContext } from "../auth/auth-context";
import { useVaultReadyEvents } from "./use-vault-ready-events";

vi.mock("../analytics/track", () => ({ track: vi.fn() }));
const mockTrack = vi.mocked(track);

const { subscribed, subscribeUserChannel } = vi.hoisted(() => {
	// Live subscriptions by event; unsubscribe removes the entry.
	const subscribed: Record<string, (payload: unknown) => void> = {};
	const subscribeUserChannel = vi.fn(
		async (_opts: { userId: string }, event: string, handler: (payload: unknown) => void) => {
			subscribed[event] = handler;
			return () => {
				delete subscribed[event];
			};
		},
	);
	return { subscribed, subscribeUserChannel };
});

vi.mock("../api/channel", () => ({ subscribeUserChannel }));

// Stable adapter, so the hook's effect (keyed on getToken) doesn't re-run.
const authAdapter: AuthAdapter = {
	isLoaded: true,
	isSignedIn: true,
	user: { email: "u@example.com" },
	getToken: async () => "tok-test",
	logout: async () => {},
	hasBuiltInUI: false,
};

function wrap({ children }: { children: React.ReactNode }) {
	return React.createElement(AuthContext.Provider, { value: authAdapter }, children);
}

describe("useVaultReadyEvents", () => {
	beforeEach(() => {
		subscribeUserChannel.mockClear();
		mockTrack.mockClear();
		for (const k of Object.keys(subscribed)) {
			delete subscribed[k];
		}
	});

	it("connects to user:{userId} and subscribes to vault_created + vault_populated", async () => {
		renderHook(() => useVaultReadyEvents({ userId: "42", enabled: true }), { wrapper: wrap });
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});
		expect(subscribeUserChannel).toHaveBeenCalledWith(
			expect.objectContaining({ userId: "42" }),
			expect.any(String),
			expect.any(Function),
			expect.any(Function),
		);
		expect(subscribed.vault_created).toBeDefined();
		expect(subscribed.vault_populated).toBeDefined();
	});

	it("flips vaultCreated + records vaultId when vault_created fires", async () => {
		const { result } = renderHook(() => useVaultReadyEvents({ userId: "42", enabled: true }), {
			wrapper: wrap,
		});
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});

		act(() => {
			subscribed.vault_created!({ vault_id: "v_1" });
		});

		expect(result.current.vaultCreated).toBe(true);
		expect(result.current.vaultPopulated).toBe(false);
		expect(result.current.vaultId).toBe("v_1");
	});

	it("flips vaultPopulated (and vaultCreated) when vault_populated fires", async () => {
		const { result } = renderHook(() => useVaultReadyEvents({ userId: "42", enabled: true }), {
			wrapper: wrap,
		});
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});

		act(() => {
			subscribed.vault_populated!({ vault_id: "v_2" });
		});

		expect(result.current.vaultCreated).toBe(true);
		expect(result.current.vaultPopulated).toBe(true);
		expect(result.current.vaultId).toBe("v_2");
	});

	// This is the signal the "zero notes ever" cases had no substitute for: the
	// plugin's first sync landing is the one milestone that proves a signup
	// actually produced content, and nothing tracked it before now.
	it("emits vault_first_sync_completed when vault_populated fires", async () => {
		renderHook(() => useVaultReadyEvents({ userId: "42", enabled: true }), { wrapper: wrap });
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});

		act(() => {
			subscribed.vault_populated!({ vault_id: "v_2" });
		});

		expect(mockTrack).toHaveBeenCalledWith(
			"vault_first_sync_completed",
			expect.objectContaining({ vault_id: "v_2" }),
		);
	});

	it("does not emit vault_first_sync_completed on vault_created alone", async () => {
		renderHook(() => useVaultReadyEvents({ userId: "42", enabled: true }), { wrapper: wrap });
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});

		act(() => {
			subscribed.vault_created!({ vault_id: "v_1" });
		});

		expect(mockTrack).not.toHaveBeenCalled();
	});

	it("does not connect when enabled is false", async () => {
		renderHook(() => useVaultReadyEvents({ userId: "42", enabled: false }), { wrapper: wrap });
		await act(async () => {
			await Promise.resolve();
		});
		expect(subscribeUserChannel).not.toHaveBeenCalled();
	});

	it("does not connect when userId is null", async () => {
		renderHook(() => useVaultReadyEvents({ userId: null, enabled: true }), { wrapper: wrap });
		await act(async () => {
			await Promise.resolve();
		});
		expect(subscribeUserChannel).not.toHaveBeenCalled();
	});

	it("unsubscribes on unmount", async () => {
		const { unmount } = renderHook(() => useVaultReadyEvents({ userId: "42", enabled: true }), {
			wrapper: wrap,
		});
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});
		expect(Object.keys(subscribed)).not.toHaveLength(0);
		unmount();
		expect(subscribed).toEqual({});
	});

	// Regression for #531: a rejecting subscribe (getToken failed) must NOT
	// leak an unhandled rejection out of the fire-and-forget effect.
	it("logs a rejecting subscribe without an unhandled rejection", async () => {
		const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
		subscribeUserChannel.mockRejectedValueOnce(new Error("auth not ready"));

		renderHook(() => useVaultReadyEvents({ userId: "42", enabled: true }), { wrapper: wrap });
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});

		expect(consoleError).toHaveBeenCalledWith(
			"user channel subscribe failed (vault_created)",
			expect.any(Error),
		);
		consoleError.mockRestore();
	});
});
