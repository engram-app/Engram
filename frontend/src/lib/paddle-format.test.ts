import { describe, expect, it } from "vitest";
import { formatMinorUnits } from "./paddle-format";

// Paddle amounts are strings in the currency's lowest denomination. Paddle's
// own decimal_places decide the conversion (GET /currencies): JPY, KRW, VND
// and CLP have none, everything else it sells in has two.
describe("formatMinorUnits", () => {
	it("formats two-decimal currencies from minor units", () => {
		expect(formatMinorUnits("2000", "USD", "en-US")).toBe("$20.00");
		expect(formatMinorUnits("1234", "USD", "en-US")).toBe("$12.34");
	});

	it("formats zero-decimal currencies without dividing", () => {
		// JPY has no minor unit: 2000 minor units is 2,000 yen, not 20.
		expect(formatMinorUnits("2000", "JPY", "en-US")).toBe("¥2,000");
	});

	// Intl calls HUF and COP zero-decimal, Paddle bills them with two: 25200
	// is 252.00 forint (Paddle's HUF minimum charge), not 25,200.
	it("follows Paddle's decimals where Intl disagrees", () => {
		expect(formatMinorUnits("25200", "HUF", "en-US")).toMatch(/^HUF\s252(?:\.00)?$/u);
		expect(formatMinorUnits("298000", "COP", "en-US")).toMatch(/^COP\s2,980(?:\.00)?$/u);
	});

	it("returns null for a missing or unparseable amount or currency", () => {
		expect(formatMinorUnits(null, "USD")).toBeNull();
		expect(formatMinorUnits(undefined, "USD")).toBeNull();
		expect(formatMinorUnits("abc", "USD")).toBeNull();
		expect(formatMinorUnits("2000", null)).toBeNull();
	});
});
