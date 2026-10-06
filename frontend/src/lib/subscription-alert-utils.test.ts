import { describe, expect, it } from "vitest";
import { translate } from "@/i18n/translate";
import type { Translate } from "@/lib/translator";
import { deriveSubscriptionAlert } from "./subscription-alert-utils";

const t: Translate = (en, vars) => translate({}, en, vars);
const canceled = { status: "canceled", canceledAt: "2026-10-06T12:00:00Z" } as const;

describe("deriveSubscriptionAlert dates", () => {
	it("formats the date as it always did for English", () => {
		expect(deriveSubscriptionAlert(canceled, t)?.message).toBe(
			"This subscription was canceled on Oct 6, 2026.",
		);
		expect(deriveSubscriptionAlert(canceled, t, "en")?.message).toBe(
			"This subscription was canceled on Oct 6, 2026.",
		);
	});
	it("formats the date in the app language", () => {
		expect(deriveSubscriptionAlert(canceled, t, "de")?.message).toContain("6. Okt. 2026");
	});
	it("formats a scheduled pause pair in the app language", () => {
		const alert = deriveSubscriptionAlert(
			{
				status: "active",
				scheduledChange: {
					action: "pause",
					effectiveAt: "2026-10-06T12:00:00Z",
					resumeAt: "2026-11-06T12:00:00Z",
				},
			},
			t,
			"de",
		);
		expect(alert?.message).toContain("6. Okt. 2026");
		expect(alert?.message).toContain("6. Nov. 2026");
	});
});
