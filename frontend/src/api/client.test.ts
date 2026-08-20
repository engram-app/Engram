import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError, api, isNotFound, LimitExceededError, setUpgradeHandler } from "./client";

describe("isNotFound", () => {
	it("is true only for a 404 ApiError", () => {
		expect(isNotFound(new ApiError(404, "not found"))).toBe(true);
		expect(isNotFound(new ApiError(500, "server error"))).toBe(false);
		expect(isNotFound(new Error("network down"))).toBe(false);
		expect(isNotFound(null)).toBe(false);
	});
});

describe("api client 402 handling", () => {
	beforeEach(() => {
		setUpgradeHandler(null);
		vi.restoreAllMocks();
	});

	it("calls upgradeHandler and throws LimitExceededError on 402", async () => {
		const handler = vi.fn();
		setUpgradeHandler(handler);

		globalThis.fetch = vi.fn().mockResolvedValue(
			new Response(
				JSON.stringify({
					error: "limit_exceeded",
					reason: "notes_cap_exceeded",
					limit_key: "notes_cap",
					limit: 10_000,
					current: 10_000,
					upgrade_url: "https://app.engram.page/settings/billing",
				}),
				{ status: 402, headers: { "Content-Type": "application/json" } },
			),
		);

		await expect(api.post("/notes", {})).rejects.toMatchObject({
			name: "LimitExceededError",
			reason: "notes_cap_exceeded",
			limitKey: "notes_cap",
			limit: 10_000,
			current: 10_000,
			upgradeUrl: "https://app.engram.page/settings/billing",
		});
		expect(handler).toHaveBeenCalledWith("notes_cap_exceeded");
	});

	it("does not crash when no upgradeHandler is registered", async () => {
		setUpgradeHandler(null);

		globalThis.fetch = vi.fn().mockResolvedValue(
			new Response(
				JSON.stringify({
					error: "limit_exceeded",
					reason: "vaults_cap_exceeded",
				}),
				{ status: 402, headers: { "Content-Type": "application/json" } },
			),
		);

		await expect(api.post("/vaults/register", {})).rejects.toBeInstanceOf(LimitExceededError);
	});

	it("LimitExceededError carries null fields when body is empty", async () => {
		globalThis.fetch = vi.fn().mockResolvedValue(new Response("not-json", { status: 402 }));

		try {
			await api.get("/anything");
			expect.fail("should have thrown");
		} catch (e) {
			expect(e).toBeInstanceOf(LimitExceededError);
			const err = e as LimitExceededError;
			expect(err.reason).toBe("unknown");
			expect(err.limitKey).toBeNull();
			expect(err.limit).toBeNull();
			expect(err.current).toBeNull();
			expect(err.upgradeUrl).toBeNull();
		}
	});

	it("non-402 errors still throw ApiError", async () => {
		globalThis.fetch = vi
			.fn()
			.mockResolvedValue(new Response(JSON.stringify({ error: "boom" }), { status: 500 }));

		await expect(api.get("/x")).rejects.toBeInstanceOf(ApiError);
	});

	it("derives the ApiError message from a 422 errors map when error is absent", async () => {
		// The unified controller shape is %{errors: %{field => [messages]}} with
		// no top-level `error` key — the message must surface the field detail,
		// not degrade to the generic statusText.
		globalThis.fetch = vi
			.fn()
			.mockResolvedValue(
				new Response(
					JSON.stringify({ errors: { display_name: ["should be at most 80 character(s)"] } }),
					{ status: 422, statusText: "Unprocessable Entity" },
				),
			);

		await expect(api.get("/x")).rejects.toThrow("display_name: should be at most 80 character(s)");
	});

	it("sends an X-Device-Id header on every request", async () => {
		const fetchMock = vi.fn().mockResolvedValue(new Response("{}", { status: 200 }));
		globalThis.fetch = fetchMock;

		await api.get("/anything");

		const init = fetchMock.mock.calls[0]![1] as RequestInit;
		const headers = init.headers as Headers;
		expect(headers.get("X-Device-Id")).toMatch(/^[0-9a-f-]{36}$/u);
	});
});
