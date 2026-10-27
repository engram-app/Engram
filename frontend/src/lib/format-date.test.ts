import { describe, expect, test } from "vitest";
import { formatDate, formatPropertyDate } from "./format-date";

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

describe("formatPropertyDate", () => {
	// Parsed as a local day: as UTC midnight it reads as the 29th west of UTC.
	test("formats a date-only value as that local calendar day", () => {
		expect(formatPropertyDate("2026-06-30", "date", "en-US")).toBe("06/30/2026");
	});

	test("formats a datetime with its time", () => {
		expect(formatPropertyDate("2026-06-30T14:05", "datetime", "en-US")).toBe("06/30/2026, 2:05 PM");
	});

	test("returns an unparseable value as stored", () => {
		expect(formatPropertyDate("someday", "date", "en-US")).toBe("someday");
	});
});
