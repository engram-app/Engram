import { describe, expect, it } from "vitest";
import type { Translate } from "@/i18n/translate";
import { untranslated } from "@/i18n/ui-text";
import { statusLabel } from "./format";

describe("statusLabel", () => {
	const shout: Translate = (en) => untranslated(en.toUpperCase());
	it("translates a known status", () => {
		expect(statusLabel("past_due", shout)).toBe("PAST DUE");
	});
	it("shows a translated generic label, never the wire value, for an unknown status", () => {
		expect(statusLabel("on_hold", shout)).toBe("UNKNOWN");
	});
});
