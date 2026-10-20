import { MutationObserver } from "@tanstack/react-query";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError, api } from "./client";
import { queryClient } from "./query-client";

const mockError = vi.hoisted(() => vi.fn());
const mockWarn = vi.hoisted(() => vi.fn());
vi.mock("../observability/remote-log", () => ({
	rlog: () => ({ info: vi.fn(), warn: mockWarn, error: mockError }),
}));

function respond(status: number) {
	globalThis.fetch = vi.fn().mockResolvedValue(
		new Response(JSON.stringify({ error: "boom" }), {
			status,
			headers: { "Content-Type": "application/json" },
		}),
	);
}

// Handled request failures used to reach no one: every mutation's onError
// toasts and stops, so a CORS-blocked /folders/batch-delete broke folder
// delete in prod with nothing reported anywhere.
describe("api client reports broken requests to the log pipe", () => {
	beforeEach(() => {
		mockError.mockClear();
		vi.spyOn(navigator, "onLine", "get").mockReturnValue(true);
	});

	it("reports a network/CORS failure and rethrows the original error", async () => {
		const err = new TypeError("Failed to fetch");
		// The request fails but the reachability probe gets through: the network
		// is up, so this route is broken (the CORS-blocked batch-delete shape).
		globalThis.fetch = vi
			.fn()
			.mockRejectedValueOnce(err)
			.mockResolvedValueOnce(new Response(null, { status: 200 }));

		await expect(api.post("/folders/batch-delete", { ids: [] })).rejects.toBe(err);

		await vi.waitFor(() => expect(mockError).toHaveBeenCalledTimes(1));
		expect(mockError.mock.calls[0]?.[0]).toBe("api_request");
		const reported = String(mockError.mock.calls[0]?.[1]);
		// URL goes through scrubUrl: note paths travel in URLs, so only the
		// route shape is reported (prod keeps the resource, e.g. /folders/:seg).
		expect(reported).toMatch(/^network_error POST \S*\/:seg/);
	});

	it("reports a 5xx and still throws ApiError", async () => {
		respond(500);

		await expect(api.get("/folders")).rejects.toBeInstanceOf(ApiError);

		// Deferred one tick: a caller that retries gets to claim the failure first.
		await vi.waitFor(() => expect(mockError).toHaveBeenCalledTimes(1));
		expect(String(mockError.mock.calls[0]?.[1])).toMatch(/^http_500 GET /);
	});

	it.each([400, 401, 403, 404, 409, 422])("does not report an expected %i", async (status) => {
		respond(status);

		await expect(api.get("/folders")).rejects.toBeInstanceOf(ApiError);

		await new Promise((r) => setTimeout(r, 0));
		expect(mockError).not.toHaveBeenCalled();
	});

	it("does not report an aborted request", async () => {
		globalThis.fetch = vi.fn().mockRejectedValue(new DOMException("aborted", "AbortError"));

		await expect(api.get("/folders")).rejects.toThrow("aborted");

		await new Promise((r) => setTimeout(r, 0));
		expect(mockError).not.toHaveBeenCalled();
	});

	it("does not report a network failure while the browser is offline", async () => {
		vi.spyOn(navigator, "onLine", "get").mockReturnValue(false);
		globalThis.fetch = vi.fn().mockRejectedValue(new TypeError("Failed to fetch"));

		await expect(api.get("/folders")).rejects.toThrow("Failed to fetch");

		await new Promise((r) => setTimeout(r, 0));
		expect(mockError).not.toHaveBeenCalled();
	});

	// navigator.onLine stays true through a laptop wake or a dead Wi-Fi: the
	// browser still thinks it has a link. 2026-10-19 one user's wake fired six
	// network_errors (/me, /vaults, /tags, ...) in the same millisecond and paged.
	it("does not report a network failure when the API is unreachable too", async () => {
		globalThis.fetch = vi.fn().mockRejectedValue(new TypeError("Failed to fetch"));

		await expect(api.get("/me")).rejects.toThrow("Failed to fetch");

		await vi.waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(2));
		await new Promise((r) => setTimeout(r, 0));
		expect(mockError).not.toHaveBeenCalled();
	});

	// A wake fails every in-flight request at once. One probe answers for all
	// of them; one per failure hammers a host that may really be down.
	it("shares one reachability probe across concurrent failures", async () => {
		globalThis.fetch = vi.fn().mockRejectedValue(new TypeError("Failed to fetch"));

		await Promise.allSettled([api.get("/me"), api.get("/vaults"), api.get("/tags")]);

		await vi.waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(4));
		await new Promise((r) => setTimeout(r, 0));
		expect(globalThis.fetch).toHaveBeenCalledTimes(4);
		expect(mockError).not.toHaveBeenCalled();
	});
});

// 2026-10-20 a user's five boot GETs failed once and succeeded on React Query's
// retry a second later. They saw nothing, but every attempt was reported and
// the alert paged. Only a request's FINAL failure is someone's problem.
describe("api client reports only a request's final failure", () => {
	beforeEach(() => {
		mockError.mockClear();
		vi.spyOn(navigator, "onLine", "get").mockReturnValue(true);
	});

	function okJson() {
		return new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
	}

	it("does not report a query that fails once and succeeds on retry", async () => {
		globalThis.fetch = vi
			.fn()
			.mockRejectedValueOnce(new TypeError("Failed to fetch"))
			.mockResolvedValue(okJson());

		await queryClient.fetchQuery({
			queryKey: ["report-test", "recovers"],
			queryFn: () => api.get("/me"),
			retry: 1,
			retryDelay: 0,
		});

		await new Promise((r) => setTimeout(r, 10));
		expect(mockError).not.toHaveBeenCalled();
	});

	it("reports a query that fails every attempt exactly once", async () => {
		respond(503);

		await expect(
			queryClient.fetchQuery({
				queryKey: ["report-test", "fails"],
				queryFn: () => api.get("/me"),
				retry: 1,
				retryDelay: 0,
			}),
		).rejects.toBeInstanceOf(ApiError);

		await vi.waitFor(() => expect(mockError).toHaveBeenCalledTimes(1));
		await new Promise((r) => setTimeout(r, 10));
		expect(mockError).toHaveBeenCalledTimes(1);
		expect(String(mockError.mock.calls[0]?.[1])).toMatch(/^http_503 GET /);
	});

	it("reports a failed mutation once", async () => {
		respond(500);

		const mutation = new MutationObserver(queryClient, {
			mutationFn: () => api.post("/folders/batch-delete", { ids: [] }),
		});
		await expect(mutation.mutate()).rejects.toBeInstanceOf(ApiError);

		await vi.waitFor(() => expect(mockError).toHaveBeenCalledTimes(1));
		await new Promise((r) => setTimeout(r, 10));
		expect(mockError).toHaveBeenCalledTimes(1);
	});
});

// "Failed to fetch" says nothing about why. Three prod users (all Chrome 155)
// lost a first attempt that never reached Cloudflare; these fields are what
// can tell a fast refusal from a stall, a backgrounded tab, or a bad link.
describe("network_error reports carry diagnostic context", () => {
	const CHROME_155_UA =
		"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36";

	beforeEach(() => {
		mockError.mockClear();
		vi.spyOn(navigator, "onLine", "get").mockReturnValue(true);
		vi.spyOn(navigator, "userAgent", "get").mockReturnValue(CHROME_155_UA);
		vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible");
	});

	it("sends browser, attempt, timing and the browser's fixed error text", async () => {
		globalThis.fetch = vi
			.fn()
			.mockRejectedValueOnce(new TypeError("Failed to fetch"))
			.mockResolvedValueOnce(new Response(null, { status: 200 }));

		await expect(api.post("/folders/batch-delete", { ids: [] })).rejects.toThrow();

		await vi.waitFor(() => expect(mockError).toHaveBeenCalledTimes(1));
		const [category, message, context] = mockError.mock.calls[0] ?? [];
		expect(category).toBe("api_request");
		// Byte-identical to before: the alert greps this text.
		expect(message).toMatch(/^network_error POST \S*\/:seg$/);
		expect(context).toEqual({
			browser: "Chrome 155",
			went_offline: false,
			attempt: 1,
			elapsed_ms: expect.any(Number),
			error_name: "TypeError",
			error_message: "Failed to fetch",
			visibility: "visible",
		});
	});

	// navigator.onLine is always true here (reports are gated on it), so the
	// signal is whether the link dropped while this request was in flight.
	it("records whether the browser went offline during the request", async () => {
		globalThis.fetch = vi.fn((url: RequestInfo | URL) => {
			if (String(url).endsWith("/api/health")) {
				return Promise.resolve(new Response(null, { status: 200 }));
			}
			window.dispatchEvent(new Event("offline"));
			return Promise.reject(new TypeError("Failed to fetch"));
		});

		await expect(api.get("/me")).rejects.toThrow();

		await vi.waitFor(() => expect(mockError).toHaveBeenCalledTimes(1));
		expect(mockError.mock.calls[0]?.[2]).toMatchObject({ went_offline: true });
	});

	it("prefers userAgentData brands, and never forwards an unknown message", async () => {
		Object.defineProperty(navigator, "userAgentData", {
			configurable: true,
			value: {
				brands: [
					{ brand: "Not=A?Brand", version: "24" },
					{ brand: "Chromium", version: "155" },
					{ brand: "Microsoft Edge", version: "155" },
				],
			},
		});
		Object.defineProperty(navigator, "connection", {
			configurable: true,
			value: { effectiveType: "3g" },
		});
		globalThis.fetch = vi
			.fn()
			.mockRejectedValueOnce(new TypeError("net::ERR_X at https://api.engram.page/me?t=secret"))
			.mockResolvedValueOnce(new Response(null, { status: 200 }));

		await expect(api.get("/me")).rejects.toThrow();

		await vi.waitFor(() => expect(mockError).toHaveBeenCalledTimes(1));
		const context = mockError.mock.calls[0]?.[2];
		expect(context.browser).toBe("Edge 155");
		expect(context.error_message).toBe("other");
		expect(context.effective_type).toBe("3g");
		Reflect.deleteProperty(navigator, "userAgentData");
		Reflect.deleteProperty(navigator, "connection");
	});

	it("counts React Query's retries in the attempt of the final failure", async () => {
		globalThis.fetch = vi.fn((url: RequestInfo | URL) =>
			String(url).endsWith("/api/health")
				? Promise.resolve(new Response(null, { status: 200 }))
				: Promise.reject(new TypeError("Load failed")),
		);

		await expect(
			queryClient.fetchQuery({
				queryKey: ["report-test", "attempts"],
				queryFn: () => api.get("/me"),
				retry: 1,
				retryDelay: 0,
			}),
		).rejects.toThrow("Load failed");

		await vi.waitFor(() => expect(mockError).toHaveBeenCalledTimes(1));
		expect(mockError.mock.calls[0]?.[2]).toMatchObject({
			attempt: 2,
			error_message: "Load failed",
		});
	});
});

// The same glitch that loses a first GET (which React Query retries) loses a
// write. A DELETE is safe to repeat, so the client repeats it once itself.
describe("idempotent writes retry once on a network error", () => {
	const isProbe = (url: RequestInfo | URL) => String(url).endsWith("/api/health");
	const requests = () =>
		vi.mocked(globalThis.fetch).mock.calls.filter(([url]) => !isProbe(url)).length;

	beforeEach(() => {
		mockError.mockClear();
		vi.spyOn(navigator, "onLine", "get").mockReturnValue(true);
	});

	/** Request outcomes in order; the reachability probe always answers. */
	function outcomes(...results: Array<Error | Response>) {
		const queue = [...results];
		globalThis.fetch = vi.fn((url: RequestInfo | URL) => {
			if (isProbe(url)) {
				return Promise.resolve(new Response(null, { status: 200 }));
			}
			const next = queue.shift();
			return next instanceof Error ? Promise.reject(next) : Promise.resolve(next ?? new Response());
		});
	}

	it("a DELETE that fails once then succeeds resolves, and reports nothing", async () => {
		outcomes(new TypeError("Failed to fetch"), new Response(null, { status: 204 }));

		await expect(api.del("/vaults/v1")).resolves.toBeUndefined();

		expect(requests()).toBe(2);
		await new Promise((r) => setTimeout(r, 10));
		expect(mockError).not.toHaveBeenCalled();
	});

	it("a DELETE that fails twice rejects and reports once, as attempt 2", async () => {
		outcomes(new TypeError("Failed to fetch"), new TypeError("Failed to fetch"));

		await expect(api.del("/vaults/v1")).rejects.toThrow("Failed to fetch");

		expect(requests()).toBe(2);
		await vi.waitFor(() => expect(mockError).toHaveBeenCalledTimes(1));
		expect(mockError.mock.calls[0]?.[1]).toMatch(/^network_error DELETE /);
		expect(mockError.mock.calls[0]?.[2]).toMatchObject({ attempt: 2 });
	});

	// The first attempt may have reached the server and deleted it; or it never
	// arrived and the id was wrong all along. The user's goal holds either way,
	// so it resolves, but the case is logged so a wrong-id bug stays countable.
	it("a 404 on the retry of a DELETE resolves, and is logged once", async () => {
		mockWarn.mockClear();
		outcomes(
			new TypeError("Failed to fetch"),
			new Response(JSON.stringify({ error: "not_found" }), { status: 404 }),
		);

		await expect(api.del("/vaults/v1")).resolves.toBeUndefined();

		expect(mockWarn).toHaveBeenCalledOnce();
		expect(mockWarn.mock.calls[0]?.[0]).toBe("api_request");
		expect(String(mockWarn.mock.calls[0]?.[1])).toMatch(/^delete_retry_not_found DELETE /);
	});

	it("a 404 on a first DELETE is still an error", async () => {
		outcomes(new Response(JSON.stringify({ error: "not_found" }), { status: 404 }));
		await expect(api.del("/vaults/v1")).rejects.toBeInstanceOf(ApiError);
	});

	it("does not retry a POST", async () => {
		outcomes(new TypeError("Failed to fetch"), new Response("{}", { status: 200 }));

		await expect(api.post("/folders/batch-delete", { ids: [] })).rejects.toThrow();

		expect(requests()).toBe(1);
		await vi.waitFor(() => expect(mockError).toHaveBeenCalledTimes(1));
		expect(mockError.mock.calls[0]?.[2]).toMatchObject({ attempt: 1 });
	});

	it("does not retry an aborted DELETE", async () => {
		outcomes(new DOMException("aborted", "AbortError"), new Response(null, { status: 204 }));
		await expect(api.del("/vaults/v1")).rejects.toThrow("aborted");
		expect(requests()).toBe(1);
	});

	// Account deletion re-sends the password, and its repeat after a success
	// that never reached us answers 401 for an account that is already gone.
	it("does not retry deleting the account", async () => {
		outcomes(new TypeError("Failed to fetch"), new Response("{}", { status: 200 }));
		await expect(api.del("/me", { password: "pw" })).rejects.toThrow();
		expect(requests()).toBe(1);
		// Reported once, as attempt 1 (and settled here, not in the next test).
		await vi.waitFor(() => expect(mockError).toHaveBeenCalledTimes(1));
		expect(mockError.mock.calls[0]?.[2]).toMatchObject({ attempt: 1 });
	});
});

// Suppressing a retried attempt used to hinge on React Query seeing the exact
// error authFetch threw. A queryFn that runs two requests (Promise.all) or
// wraps the error broke that link, and a recovered attempt still paged.
describe("retried query attempts are dropped whatever the queryFn does", () => {
	beforeEach(() => {
		mockError.mockClear();
		vi.spyOn(navigator, "onLine", "get").mockReturnValue(true);
	});

	/** /a and /b fail `failures` times each, then answer 200. */
	function failing(failures: number) {
		const seen = new Map<string, number>();
		globalThis.fetch = vi.fn((url: RequestInfo | URL) => {
			const path = String(url);
			if (path.endsWith("/api/health")) {
				return Promise.resolve(new Response(null, { status: 200 }));
			}
			const n = (seen.get(path) ?? 0) + 1;
			seen.set(path, n);
			return n <= failures
				? Promise.reject(new TypeError("Failed to fetch"))
				: Promise.resolve(new Response("{}", { status: 200 }));
		});
	}

	const both = () => Promise.all([api.get("/a"), api.get("/b")]);
	const wrapped = () =>
		api.get("/a").catch((err: unknown) => {
			throw new Error("could not load a", { cause: err });
		});

	const fetchWith = (key: string, queryFn: () => Promise<unknown>) =>
		queryClient.fetchQuery({ queryKey: ["scope-test", key], queryFn, retry: 1, retryDelay: 0 });

	const settle = () => new Promise((r) => setTimeout(r, 20));

	it("Promise.all of two GETs that both recover on retry reports nothing", async () => {
		failing(1);
		await fetchWith("all-recovers", both);
		await settle();
		expect(mockError).not.toHaveBeenCalled();
	});

	it("Promise.all of two GETs failing every attempt reports each once", async () => {
		failing(99);
		await expect(fetchWith("all-fails", both)).rejects.toThrow();
		await vi.waitFor(() => expect(mockError).toHaveBeenCalledTimes(2));
		await settle();
		expect(mockError).toHaveBeenCalledTimes(2);
		// Both scrub to the same route shape (/api/:seg); one report each.
		expect(mockError.mock.calls.map((c) => String(c[1]))).toEqual([
			expect.stringMatching(/^network_error GET /),
			expect.stringMatching(/^network_error GET /),
		]);
		expect(mockError.mock.calls.map((c) => c[2].attempt)).toEqual([2, 2]);
	});

	it("a wrapped error that recovers on retry reports nothing", async () => {
		failing(1);
		await fetchWith("wrapped-recovers", wrapped);
		await settle();
		expect(mockError).not.toHaveBeenCalled();
	});

	it("a wrapped error failing every attempt reports once", async () => {
		failing(99);
		await expect(fetchWith("wrapped-fails", wrapped)).rejects.toThrow("could not load a");
		await vi.waitFor(() => expect(mockError).toHaveBeenCalledTimes(1));
		await settle();
		expect(mockError).toHaveBeenCalledTimes(1);
	});
});
