import { describe, expect, it } from "vitest";
import { whenLoaded } from "./when-loaded";

const PENDING = Symbol("pending");

// Settled value, or PENDING if the promise has not settled after a macrotask.
function settledOrPending<T>(promise: Promise<T>): Promise<T | typeof PENDING> {
	return Promise.race([
		promise,
		new Promise<typeof PENDING>((r) => setTimeout(() => r(PENDING), 0)),
	]);
}

describe("whenLoaded", () => {
	it("resolves the module when the import loads", async () => {
		const mod = { default: "x" };
		await expect(whenLoaded(Promise.resolve(mod))).resolves.toBe(mod);
	});

	// vite:preloadError's preventDefault() makes the dynamic import resolve undefined
	// while the page reloads; reading `.default` of it would throw a TypeError.
	it("never settles, without throwing, when the import resolves nothing", async () => {
		await expect(settledOrPending(whenLoaded(Promise.resolve(undefined)))).resolves.toBe(PENDING);
	});

	it("passes a rejected import through", async () => {
		const err = new Error("chunk 404");
		await expect(whenLoaded(Promise.reject(err))).rejects.toBe(err);
	});
});
