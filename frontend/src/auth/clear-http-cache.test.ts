import { afterEach, describe, expect, it, vi } from "vitest";
import { setApiBase } from "../api/base";
import { clearHttpCache } from "./clear-http-cache";

describe("clearHttpCache", () => {
	afterEach(() => {
		vi.restoreAllMocks();
		setApiBase("");
	});

	it("POSTs /api/auth/clear-cache on the API origin, with keepalive", () => {
		setApiBase("https://api.example.test/api");
		const fetchMock = vi
			.spyOn(globalThis, "fetch")
			.mockResolvedValue(new Response(null, { status: 204 }));

		clearHttpCache();

		expect(fetchMock).toHaveBeenCalledWith(
			"https://api.example.test/api/auth/clear-cache",
			expect.objectContaining({ method: "POST", credentials: "include", keepalive: true }),
		);
	});

	it("returns at once even when the browser never answers", () => {
		vi.spyOn(globalThis, "fetch").mockReturnValue(new Promise(() => undefined));

		expect(clearHttpCache()).toBeUndefined();
	});

	it("never throws: a failed request is logged, not raised", async () => {
		const error = vi.spyOn(console, "error").mockImplementation(() => undefined);
		vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("offline"));

		clearHttpCache();

		await vi.waitFor(() => expect(error).toHaveBeenCalled());
	});
});
