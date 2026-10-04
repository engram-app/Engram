import { describe, expect, test } from "vitest";
import { formatDate } from "./format-date";

describe("formatDate", () => {
	test("formats an ISO timestamp as a short date in the given locale", () => {
		expect(formatDate("2026-10-04T12:00:00Z", "en-US")).toBe("Oct 4, 2026");
		expect(formatDate("2026-10-04T12:00:00Z", "de-DE")).toBe("4. Okt. 2026");
	});

	test("defaults to the runtime locale", () => {
		expect(formatDate("2026-10-04T12:00:00Z")).toBe(
			new Date("2026-10-04T12:00:00Z").toLocaleDateString(undefined, {
				year: "numeric",
				month: "short",
				day: "numeric",
			}),
		);
	});
});
