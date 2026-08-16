/**
 * The account-delete password must ride the request BODY.
 *
 * It used to be `DELETE /me?password=hunter2`, which is written to Phoenix's
 * access log, the load balancer's, every proxy in between, browser history, and
 * Sentry's fetch breadcrumb — a credential the user typed into a confirm
 * dialog, spread across three log stores.
 *
 * The backend test that came with the fix does NOT pin this: `UsersController`
 * reads Phoenix's merged body+query params, so it accepted a body before the
 * change and still accepts a query string now. Reverting the frontend to the
 * query form leaves the whole Elixir suite green. This is the test that fails.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";

const { authFetchMock } = vi.hoisted(() => ({ authFetchMock: vi.fn() }));

// Partial mock: other modules in this import graph pull real exports off
// `./base` (tracing flags), so replacing the whole module breaks them.
vi.mock("./base", async (importOriginal) => ({
	...(await importOriginal<typeof import("./base")>()),
	getApiBase: () => "https://api.engram.test",
}));

// The client's own fetch wrapper is the seam: assert on what reaches it.
vi.stubGlobal("fetch", authFetchMock);

beforeEach(() => {
	authFetchMock.mockReset();
	authFetchMock.mockResolvedValue({
		ok: true,
		status: 204,
		headers: new Headers({ "content-length": "0" }),
		json: async () => ({}),
	});
});

describe("api.del carries a body", () => {
	it("sends the payload as the request body, leaving the URL bare", async () => {
		const { api } = await import("./client");

		await api.del("/me", { password: "hunter2" });

		const [url, init] = authFetchMock.mock.calls[0] ?? [];
		expect(String(url)).not.toContain("hunter2");
		expect(String(url)).not.toContain("password=");
		expect(init?.method).toBe("DELETE");
		expect(String(init?.body)).toContain("hunter2");
	});

	// The other three del() callers pass nothing; a body of `undefined` must
	// stay a no-op rather than becoming the string "undefined".
	it("sends no body when none is given", async () => {
		const { api } = await import("./client");

		await api.del("/connections/7");

		const [, init] = authFetchMock.mock.calls[0] ?? [];
		expect(init?.body).toBeUndefined();
	});
});
