import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getStoredLocale, setStoredLocale } from "./storage";

describe("locale storage", () => {
	beforeEach(() => window.localStorage.clear());
	afterEach(() => vi.restoreAllMocks());

	it("round-trips a valid locale", () => {
		setStoredLocale("ja");
		expect(getStoredLocale()).toBe("ja");
	});
	it("returns null when nothing is stored", () => {
		expect(getStoredLocale()).toBeNull();
	});
	it("ignores an unknown stored value", () => {
		window.localStorage.setItem("engram:locale", "klingon");
		expect(getStoredLocale()).toBeNull();
	});
	it("returns null when localStorage throws", () => {
		vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
			throw new Error("denied");
		});
		expect(getStoredLocale()).toBeNull();
	});
	it("does not throw when localStorage write throws", () => {
		vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
			throw new Error("denied");
		});
		expect(() => setStoredLocale("de")).not.toThrow();
	});
});
