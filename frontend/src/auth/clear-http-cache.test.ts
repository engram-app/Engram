import { afterEach, describe, expect, it, vi } from "vitest";
import { setApiBase } from "../api/base";
import { clearHttpCache } from "./clear-http-cache";

describe("clearHttpCache", () => {
	afterEach(() => {
		vi.restoreAllMocks();
		setApiBase("");
	});

	it("POSTs /api/auth/clear-cache on the API origin", async () => {
		setApiBase("https://api.example.test/api");
		const fetchMock = vi
			.spyOn(globalThis, "fetch")
			.mockResolvedValue(new Response(null, { status: 204 }));

		await clearHttpCache();

		expect(fetchMock).toHaveBeenCalledWith(
			"https://api.example.test/api/auth/clear-cache",
			expect.objectContaining({ method: "POST" }),
		);
	});

	it("never throws: a failed request must not block sign-out", async () => {
		vi.spyOn(console, "error").mockImplementation(() => undefined);
		vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("offline"));

		await expect(clearHttpCache()).resolves.toBeUndefined();
	});
});
