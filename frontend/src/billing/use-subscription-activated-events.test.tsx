import { act, renderHook } from "@testing-library/react";
import React from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { type AuthAdapter, AuthContext } from "../auth/auth-context";
import { useSubscriptionActivatedEvents } from "./use-subscription-activated-events";

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

describe("useSubscriptionActivatedEvents", () => {
	beforeEach(() => {
		subscribeUserChannel.mockClear();
		for (const k of Object.keys(subscribed)) {
			delete subscribed[k];
		}
	});

	it("connects to user:{userId} and subscribes to subscription_activated", async () => {
		const onActivated = vi.fn();
		renderHook(() => useSubscriptionActivatedEvents({ userId: "42", enabled: true, onActivated }), {
			wrapper: wrap,
		});
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
		expect(subscribed.subscription_activated).toBeDefined();
	});

	it("invokes onActivated when the channel fires subscription_activated", async () => {
		const onActivated = vi.fn();
		renderHook(() => useSubscriptionActivatedEvents({ userId: "42", enabled: true, onActivated }), {
			wrapper: wrap,
		});
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});

		act(() => {
			subscribed.subscription_activated!({
				tier: "starter",
				status: "trialing",
				subscription_id: "sub_1",
			});
		});

		expect(onActivated).toHaveBeenCalledWith({
			tier: "starter",
			status: "trialing",
			subscription_id: "sub_1",
		});
	});

	it("does not connect when enabled is false", async () => {
		renderHook(
			() =>
				useSubscriptionActivatedEvents({
					userId: "42",
					enabled: false,
					onActivated: vi.fn(),
				}),
			{ wrapper: wrap },
		);
		await act(async () => {
			await Promise.resolve();
		});
		expect(subscribeUserChannel).not.toHaveBeenCalled();
	});

	it("does not connect when userId is null", async () => {
		renderHook(
			() =>
				useSubscriptionActivatedEvents({
					userId: null,
					enabled: true,
					onActivated: vi.fn(),
				}),
			{ wrapper: wrap },
		);
		await act(async () => {
			await Promise.resolve();
		});
		expect(subscribeUserChannel).not.toHaveBeenCalled();
	});

	it("unsubscribes on unmount", async () => {
		const { unmount } = renderHook(
			() =>
				useSubscriptionActivatedEvents({
					userId: "42",
					enabled: true,
					onActivated: vi.fn(),
				}),
			{ wrapper: wrap },
		);
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});
		expect(Object.keys(subscribed)).not.toHaveLength(0);
		unmount();
		expect(subscribed).toEqual({});
	});
});
