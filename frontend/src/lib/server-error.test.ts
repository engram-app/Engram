import { describe, expect, it } from "vitest";
import { ApiError } from "@/api/client";
import { englishT } from "@/i18n/translate";
import { untranslated } from "@/i18n/ui-text";
import { serverErrorMessage } from "./server-error";

const fallback = untranslated("FALLBACK");

describe("serverErrorMessage", () => {
	it("maps a known error code to translated text", () => {
		expect(serverErrorMessage(new ApiError(409, "last_admin"), fallback, englishT)).toBe(
			"Can't remove the last admin.",
		);
	});
	it("maps by status when the code is unknown", () => {
		expect(serverErrorMessage(new ApiError(403, "forbidden"), fallback, englishT)).toBe(
			"You don't have permission to do that.",
		);
		expect(serverErrorMessage(new ApiError(429, "slow down"), fallback, englishT)).toBe(
			"Too many requests. Try again in a moment.",
		);
	});
	// Server text is English whatever the UI language, so it never reaches the user.
	it("falls back for unknown codes, plain errors and non-errors", () => {
		expect(serverErrorMessage(new ApiError(422, "update_failed"), fallback, englishT)).toBe(
			"FALLBACK",
		);
		expect(serverErrorMessage(new ApiError(500, ""), fallback, englishT)).toBe("FALLBACK");
		expect(serverErrorMessage(new Error("Network down"), fallback, englishT)).toBe("FALLBACK");
		expect(serverErrorMessage("boom", fallback, englishT)).toBe("FALLBACK");
		expect(serverErrorMessage(undefined, fallback, englishT)).toBe("FALLBACK");
	});
});
