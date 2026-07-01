import { act, renderHook } from "@testing-library/react";
import React from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { type AuthAdapter, AuthContext } from "../auth/auth-context";

const {
	channelHandlers,
	channelOn,
	socketChannelMock,
	socketConnectMock,
	socketDisconnectMock,
	socketCtor,
} = vi.hoisted(() => {
	const channelHandlers: Record<string, (payload: unknown) => void> = {};
	const channelOn = vi.fn((event: string, cb: (payload: unknown) => void) => {
		channelHandlers[event] = cb;
	});
	const channelMock = {
		on: channelOn,
		join: () => ({ receive: () => ({}) }),
	};
	const socketChannelMock = vi.fn(() => channelMock);
	const socketConnectMock = vi.fn();
	const socketDisconnectMock = vi.fn();
	// Phoenix's Socket is invoked with `new` — use a constructor function (not a
	// vi.fn() arrow returning an object, which Mock's `new` semantics reject).
	const socketCtor = vi.fn(function MockSocket(this: object, ..._args: unknown[]) {
		Object.assign(this, {
			connect: socketConnectMock,
			channel: socketChannelMock,
			disconnect: socketDisconnectMock,
		});
	});
	return {
		channelHandlers,
		channelOn,
		socketChannelMock,
		socketConnectMock,
		socketDisconnectMock,
		socketCtor,
	};
});

vi.mock("phoenix", () => ({ Socket: socketCtor }));

import { useVaultReadyEvents } from "./use-vault-ready-events";

// getToken is the lynchpin: the hook's fire-and-forget connect() awaits it.
// A getToken that rejects (or isn't a function) used to crash the vitest run
// with an unhandled rejection — see #531 / #652. `tokenImpl` is swappable per
// test, but the adapter object itself is STABLE so the hook's effect (keyed on
// getToken) doesn't spuriously re-run on every re-render.
let tokenImpl: () => Promise<string | null> = async () => "tok-test";

const authAdapter: AuthAdapter = {
	isLoaded: true,
	isSignedIn: true,
	user: { email: "u@example.com" },
	getToken: () => tokenImpl(),
	logout: async () => {},
	hasBuiltInUI: false,
};

function wrap({ children }: { children: React.ReactNode }) {
	return React.createElement(AuthContext.Provider, { value: authAdapter }, children);
}

describe("useVaultReadyEvents", () => {
	beforeEach(() => {
		tokenImpl = async () => "tok-test";
		socketCtor.mockClear();
		socketChannelMock.mockClear();
		socketConnectMock.mockClear();
		socketDisconnectMock.mockClear();
		channelOn.mockClear();
		for (const k of Object.keys(channelHandlers)) delete channelHandlers[k];
	});

	it("connects to user:{userId} and subscribes to vault_created + vault_populated", async () => {
		renderHook(() => useVaultReadyEvents({ userId: "42", enabled: true }), { wrapper: wrap });
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});
		expect(socketCtor).toHaveBeenCalledWith("/socket", { params: { token: "tok-test" } });
		expect(socketChannelMock).toHaveBeenCalledWith("user:42");
		expect(channelHandlers["vault_created"]).toBeDefined();
		expect(channelHandlers["vault_populated"]).toBeDefined();
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
			channelHandlers["vault_created"]!({ vault_id: "v_1" });
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
			channelHandlers["vault_populated"]!({ vault_id: "v_2" });
		});

		expect(result.current.vaultCreated).toBe(true);
		expect(result.current.vaultPopulated).toBe(true);
		expect(result.current.vaultId).toBe("v_2");
	});

	it("does not connect when enabled is false", async () => {
		renderHook(() => useVaultReadyEvents({ userId: "42", enabled: false }), { wrapper: wrap });
		await act(async () => {
			await Promise.resolve();
		});
		expect(socketCtor).not.toHaveBeenCalled();
	});

	it("does not connect when userId is null", async () => {
		renderHook(() => useVaultReadyEvents({ userId: null, enabled: true }), { wrapper: wrap });
		await act(async () => {
			await Promise.resolve();
		});
		expect(socketCtor).not.toHaveBeenCalled();
	});

	it("disconnects the socket on unmount", async () => {
		const { unmount } = renderHook(() => useVaultReadyEvents({ userId: "42", enabled: true }), {
			wrapper: wrap,
		});
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});
		unmount();
		expect(socketDisconnectMock).toHaveBeenCalledOnce();
	});

	// Regression for #531: a rejecting getToken must NOT leak an unhandled
	// rejection out of the fire-and-forget connect(). The hook catches + logs
	// it instead, and never reaches socket construction.
	it("swallows a rejecting getToken without an unhandled rejection", async () => {
		const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
		tokenImpl = () => Promise.reject(new Error("auth not ready"));

		renderHook(() => useVaultReadyEvents({ userId: "42", enabled: true }), { wrapper: wrap });
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});

		expect(socketCtor).not.toHaveBeenCalled();
		expect(consoleError).toHaveBeenCalledWith("user channel connect failed", expect.any(Error));
		consoleError.mockRestore();
	});
});
