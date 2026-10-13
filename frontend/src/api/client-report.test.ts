import { beforeEach, describe, expect, it, vi } from "vitest";
import { captureError } from "../sentry";
import { ApiError, api } from "./client";

vi.mock("../sentry", async (orig) => ({
	...(await orig<typeof import("../sentry")>()),
	captureError: vi.fn().mockResolvedValue(undefined),
}));
const mockCapture = vi.mocked(captureError);

function respond(status: number) {
	globalThis.fetch = vi
		.fn()
		.mockResolvedValue(
			new Response(JSON.stringify({ error: "boom" }), {
				status,
				headers: { "Content-Type": "application/json" },
			}),
		);
}

// Handled request failures used to reach no one: every mutation's onError
// toasts and stops, so a CORS-blocked /folders/batch-delete broke folder
// delete in prod with nothing in Sentry.
describe("api client reports broken requests to Sentry", () => {
	beforeEach(() => {
		mockCapture.mockClear();
		vi.spyOn(navigator, "onLine", "get").mockReturnValue(true);
	});

	it("reports a network/CORS failure and rethrows the original error", async () => {
		const err = new TypeError("Failed to fetch");
		globalThis.fetch = vi.fn().mockRejectedValue(err);

		await expect(api.post("/folders/batch-delete", { ids: [] })).rejects.toBe(err);

		expect(mockCapture).toHaveBeenCalledTimes(1);
		const reported = mockCapture.mock.calls[0]?.[0] as Error;
		expect(reported.name).toBe("ApiRequestError");
		// URL goes through scrubUrl: note paths travel in URLs, so only the
		// route shape is reported (prod keeps the resource, e.g. /folders/:seg).
		expect(reported.message).toMatch(/^network_error POST \S*\/:seg/);
	});

	it("reports a 5xx and still throws ApiError", async () => {
		respond(500);

		await expect(api.get("/folders")).rejects.toBeInstanceOf(ApiError);

		expect(mockCapture).toHaveBeenCalledTimes(1);
		const reported = mockCapture.mock.calls[0]?.[0] as Error;
		expect(reported.message).toMatch(/^http_500 GET /);
	});

	it.each([400, 401, 403, 404, 409, 422])("does not report an expected %i", async (status) => {
		respond(status);

		await expect(api.get("/folders")).rejects.toBeInstanceOf(ApiError);

		expect(mockCapture).not.toHaveBeenCalled();
	});

	it("does not report an aborted request", async () => {
		globalThis.fetch = vi.fn().mockRejectedValue(new DOMException("aborted", "AbortError"));

		await expect(api.get("/folders")).rejects.toThrow("aborted");

		expect(mockCapture).not.toHaveBeenCalled();
	});

	it("does not report a network failure while the browser is offline", async () => {
		vi.spyOn(navigator, "onLine", "get").mockReturnValue(false);
		globalThis.fetch = vi.fn().mockRejectedValue(new TypeError("Failed to fetch"));

		await expect(api.get("/folders")).rejects.toThrow("Failed to fetch");

		expect(mockCapture).not.toHaveBeenCalled();
	});
});
