import { beforeEach, describe, expect, it, vi } from "vitest";
import { captureSignupAttribution, sendSignupAttribution } from "./attribution";

const { patch } = vi.hoisted(() => ({ patch: vi.fn() }));
vi.mock("../api/client", () => ({
	api: { patch },
	ApiError: class ApiError extends Error {
		constructor(
			public status: number,
			message: string,
		) {
			super(message);
		}
	},
}));

const KEY = "engram:signup-attribution";

beforeEach(() => {
	sessionStorage.clear();
	patch.mockReset();
});

describe("captureSignupAttribution", () => {
	it("stashes allowlisted params and an external referrer domain", () => {
		captureSignupAttribution(
			"?utm_source=newsletter&utm_term=dropped&via=todd&return_to=/v/abc",
			"https://News.YCombinator.com/item?id=1",
			"app.engram.page",
		);

		expect(JSON.parse(sessionStorage.getItem(KEY) ?? "null")).toEqual({
			utm_source: "newsletter",
			via: "todd",
			referrer_domain: "news.ycombinator.com",
		});
	});

	it("ignores our own origin as a referrer and stores nothing when empty", () => {
		captureSignupAttribution("", "https://app.engram.page/sign-in", "app.engram.page");
		expect(sessionStorage.getItem(KEY)).toBeNull();
	});

	it("drops values outside the token charset and clamps length", () => {
		captureSignupAttribution(`?utm_source=a%20b&utm_campaign=${"x".repeat(80)}`, "", "h");
		expect(JSON.parse(sessionStorage.getItem(KEY) ?? "null")).toEqual({
			utm_campaign: "x".repeat(64),
		});
	});

	it("keeps the first touch", () => {
		captureSignupAttribution("?utm_source=first", "", "h");
		captureSignupAttribution("?utm_source=second", "", "h");
		expect(JSON.parse(sessionStorage.getItem(KEY) ?? "null")).toEqual({ utm_source: "first" });
	});
});

describe("sendSignupAttribution", () => {
	it("sends the stash once and clears it after success", async () => {
		sessionStorage.setItem(KEY, JSON.stringify({ utm_source: "newsletter" }));
		patch.mockResolvedValue({});

		await sendSignupAttribution();
		await sendSignupAttribution();

		expect(patch).toHaveBeenCalledTimes(1);
		expect(patch).toHaveBeenCalledWith("/onboarding/profile", {
			attribution: { utm_source: "newsletter" },
		});
		expect(sessionStorage.getItem(KEY)).toBeNull();
	});

	it("keeps the stash when the request fails, so a later visit retries", async () => {
		sessionStorage.setItem(KEY, JSON.stringify({ via: "todd" }));
		patch.mockRejectedValue(new Error("offline"));

		await sendSignupAttribution();

		expect(sessionStorage.getItem(KEY)).not.toBeNull();
	});

	it("drops a stash the server refused as unusable", async () => {
		const { ApiError } = await import("../api/client");
		sessionStorage.setItem(KEY, JSON.stringify({ via: "x" }));
		patch.mockRejectedValue(new ApiError(422, "invalid_attribution"));

		await sendSignupAttribution();

		expect(sessionStorage.getItem(KEY)).toBeNull();
	});

	it("does nothing without a stash", async () => {
		await sendSignupAttribution();
		expect(patch).not.toHaveBeenCalled();
	});
});
