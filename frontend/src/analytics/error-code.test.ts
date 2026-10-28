import { describe, expect, it } from "vitest";
import { ApiError, LimitExceededError } from "../api/client";
import { errorCodeOf } from "./error-code";

describe("errorCodeOf", () => {
	it.each([
		[new ApiError(404, "x"), "not_found"],
		[new ApiError(401, "x"), "auth"],
		[new ApiError(403, "x"), "auth"],
		[new ApiError(429, "x"), "rate_limited"],
		[new ApiError(500, "x"), "unknown"],
		[new TypeError("Failed to fetch"), "network"],
		[new LimitExceededError("r", null, null, null, null), "limit_exceeded"],
		[new Error("boom"), "unknown"],
		["not an error", "unknown"],
	])("buckets %# as %s", (err, code) => {
		expect(errorCodeOf(err)).toBe(code);
	});
});
