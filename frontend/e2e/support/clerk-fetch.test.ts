import { describe, expect, it } from "vitest";
import { clerkFetch } from "./clerk-fetch";

function scripted(responses: Response[]) {
	const calls: string[] = [];
	const fetchImpl = (url: string | URL | Request) => {
		calls.push(String(url));
		const next = responses.shift();
		if (!next) {
			throw new Error("no scripted response left");
		}
		return Promise.resolve(next);
	};
	return { calls, fetchImpl: fetchImpl as typeof fetch };
}

function sleeper() {
	const slept: number[] = [];
	return {
		slept,
		sleep: (ms: number) => {
			slept.push(ms);
			return Promise.resolve();
		},
	};
}

const tooMany = (headers: Record<string, string> = {}) =>
	new Response("Too Many Requests", { status: 429, headers });

describe("clerkFetch", () => {
	it("returns a non-429 response at once", async () => {
		const { calls, fetchImpl } = scripted([new Response("{}", { status: 200 })]);
		const { slept, sleep } = sleeper();

		const resp = await clerkFetch("https://api.clerk.com/v1/users", {}, { fetchImpl, sleep });

		expect(resp.status).toBe(200);
		expect(calls).toHaveLength(1);
		expect(slept).toEqual([]);
	});

	it("does not retry other errors", async () => {
		const { calls, fetchImpl } = scripted([new Response("bad", { status: 422 })]);
		const { sleep } = sleeper();

		const resp = await clerkFetch("u", {}, { fetchImpl, sleep });

		expect(resp.status).toBe(422);
		expect(calls).toHaveLength(1);
	});

	it("honors Retry-After in seconds", async () => {
		const { fetchImpl } = scripted([tooMany({ "Retry-After": "2" }), new Response("{}")]);
		const { slept, sleep } = sleeper();

		const resp = await clerkFetch("u", {}, { fetchImpl, sleep });

		expect(resp.status).toBe(200);
		expect(slept).toEqual([2000]);
	});

	it("honors Retry-After as an HTTP date", async () => {
		const at = new Date(Date.now() + 3000).toUTCString();
		const { fetchImpl } = scripted([tooMany({ "Retry-After": at }), new Response("{}")]);
		const { slept, sleep } = sleeper();

		await clerkFetch("u", {}, { fetchImpl, sleep });

		expect(slept).toHaveLength(1);
		expect(slept[0]).toBeGreaterThan(1000);
		expect(slept[0]).toBeLessThanOrEqual(3000);
	});

	it("backs off exponentially without Retry-After", async () => {
		const { calls, fetchImpl } = scripted([tooMany(), tooMany(), tooMany(), new Response("{}")]);
		const { slept, sleep } = sleeper();

		const resp = await clerkFetch("u", {}, { fetchImpl, sleep });

		expect(resp.status).toBe(200);
		expect(calls).toHaveLength(4);
		expect(slept).toEqual([500, 1000, 2000]);
	});

	it("returns the last 429 once the budget is spent", async () => {
		const { calls, fetchImpl } = scripted([
			tooMany({ "Retry-After": "1" }),
			tooMany({ "Retry-After": "30" }),
		]);
		const { slept, sleep } = sleeper();

		const resp = await clerkFetch("u", {}, { fetchImpl, sleep, budgetMs: 5000 });

		expect(resp.status).toBe(429);
		expect(calls).toHaveLength(2);
		expect(slept).toEqual([1000]);
	});
});
