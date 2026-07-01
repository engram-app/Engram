import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { encodeCursor, getCursor, MAX_UUID, setCursor } from "./cursor";

function decodeUrlB64(tok: string): string {
	return atob(tok.replace(/-/gu, "+").replace(/_/gu, "/"));
}

describe("encodeCursor", () => {
	it('matches the backend codec: url-safe base64 of "<seq>:<id>", no padding', () => {
		const tok = encodeCursor(42, MAX_UUID);
		expect(decodeUrlB64(tok)).toBe(`42:${MAX_UUID}`);
		expect(tok).not.toMatch(/[+/=]/u);
	});

	it("uses an all-f UUID sentinel for the head cursor", () => {
		expect(MAX_UUID).toBe("ffffffff-ffff-ffff-ffff-ffffffffffff");
	});
});

describe("cursor storage", () => {
	beforeEach(() => localStorage.clear());
	afterEach(() => localStorage.clear());

	it("returns null when no cursor is stored for the vault", () => {
		expect(getCursor("v1")).toBeNull();
	});

	it("persists and reads back a cursor per vault", () => {
		setCursor("v1", "tok-1");
		setCursor("v2", "tok-2");
		expect(getCursor("v1")).toBe("tok-1");
		expect(getCursor("v2")).toBe("tok-2");
	});
});
