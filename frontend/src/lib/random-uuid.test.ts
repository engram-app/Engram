import { describe, expect, it, vi } from "vitest";
import { randomUuid } from "./random-uuid";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;

/** Run `fn` with crypto.randomUUID replaced, then restore whatever was there. */
function withRandomUUID(value: unknown, fn: () => void) {
	const original = Object.getOwnPropertyDescriptor(globalThis.crypto, "randomUUID");
	Object.defineProperty(globalThis.crypto, "randomUUID", { value, configurable: true });
	try {
		fn();
	} finally {
		if (original) {
			Object.defineProperty(globalThis.crypto, "randomUUID", original);
		}
	}
}

describe("randomUuid", () => {
	// On HTTPS nothing changes: the app keeps the v4 it has always minted,
	// with full entropy and no embedded timestamp.
	it("uses crypto.randomUUID when the origin is a secure context", () => {
		const native = vi.fn(() => "11111111-2222-4333-8444-555555555555");
		withRandomUUID(native, () => {
			expect(randomUuid()).toBe("11111111-2222-4333-8444-555555555555");
			expect(native).toHaveBeenCalledTimes(1);
		});
	});

	// The case that hung a phone: randomUUID is undefined over plain http from a
	// LAN address, and calling it throws rather than returning undefined.
	it("falls back to uuid7 when crypto.randomUUID is unavailable", () => {
		withRandomUUID(undefined, () => {
			const id = randomUuid();
			expect(id).toMatch(UUID);
			// Version nibble 7 — proof the fallback, not the native path, ran.
			expect(id[14]).toBe("7");
		});
	});

	it("does not repeat itself", () => {
		withRandomUUID(undefined, () => {
			expect(randomUuid()).not.toBe(randomUuid());
		});
	});
});
