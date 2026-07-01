import { describe, expect, test } from "vitest";
import { coerceValue, effectiveType, inferType, isPropertyType } from "./property-types";

describe("inferType", () => {
	test("scalars and containers", () => {
		expect(inferType("hi")).toBe("text");
		expect(inferType(["a", "b"])).toBe("list");
		expect(inferType(3)).toBe("number");
		expect(inferType(true)).toBe("checkbox");
		expect(inferType("2026-06-30")).toBe("date");
		expect(inferType("2026-06-30T14:05:00")).toBe("datetime");
		expect(inferType(null)).toBe("text");
		expect(inferType({ a: 1 })).toBe("text");
	});
});

describe("effectiveType", () => {
	test("valid override wins, invalid falls back", () => {
		expect(effectiveType("2026-06-30", "text")).toBe("text");
		expect(effectiveType("hi", "date")).toBe("date");
		expect(effectiveType("hi", "bogus")).toBe("text");
		expect(effectiveType(["a"], null)).toBe("list");
	});
});

describe("coerceValue", () => {
	test("conversions", () => {
		expect(coerceValue("hi", "list")).toEqual(["hi"]);
		expect(coerceValue(["a", "b"], "text")).toBe("a, b");
		expect(coerceValue("3.5", "number")).toBe(3.5);
		expect(coerceValue("nope", "number")).toBeNull();
		expect(coerceValue("yes", "checkbox")).toBe(true);
		expect(coerceValue("", "checkbox")).toBe(false);
		expect(coerceValue(42, "text")).toBe("42");
		expect(coerceValue("", "list")).toEqual([]);
	});
});

describe("isPropertyType", () => {
	test("guards", () => {
		expect(isPropertyType("date")).toBe(true);
		expect(isPropertyType("bogus")).toBe(false);
	});
});
