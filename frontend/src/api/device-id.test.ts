import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { __resetDeviceIdCache, getDeviceId } from "./device-id";

describe("getDeviceId", () => {
	beforeEach(() => {
		localStorage.clear();
		__resetDeviceIdCache();
	});
	afterEach(() => {
		localStorage.clear();
		__resetDeviceIdCache();
	});

	it("mints a UUID and persists it to localStorage", () => {
		const id = getDeviceId();
		expect(id).toMatch(/^[0-9a-f-]{36}$/u);
		expect(localStorage.getItem("engram.deviceId")).toBe(id);
	});

	// crypto.randomUUID is a secure-context-only API, so it is undefined when the
	// app is served over plain http from anything but localhost — a phone on the
	// LAN dev server, a self-hoster on their own network. This is the first call
	// after sign-in, so a TypeError here surfaced as a permanent loading screen
	// with nothing in client_logs, the log shipper needing the device id too.
	it("mints an id without crypto.randomUUID, which is unavailable on an insecure origin", () => {
		const original = Object.getOwnPropertyDescriptor(globalThis.crypto, "randomUUID");
		Object.defineProperty(globalThis.crypto, "randomUUID", {
			value: undefined,
			configurable: true,
		});
		try {
			const id = getDeviceId();
			expect(id).toMatch(/^[0-9a-f-]{36}$/u);
			expect(localStorage.getItem("engram.deviceId")).toBe(id);
		} finally {
			if (original) {
				Object.defineProperty(globalThis.crypto, "randomUUID", original);
			}
		}
	});

	it("returns the same id across calls (stable)", () => {
		expect(getDeviceId()).toBe(getDeviceId());
	});

	it("reads an existing id from storage rather than minting a new one", () => {
		getDeviceId();
		const stored = localStorage.getItem("engram.deviceId");
		__resetDeviceIdCache();
		expect(getDeviceId()).toBe(stored);
	});
});
