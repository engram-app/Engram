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
