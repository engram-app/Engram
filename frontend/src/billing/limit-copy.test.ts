import { describe, expect, it } from "vitest";
import { copyFor } from "./limit-copy";

describe("limit-copy", () => {
	it("maps notes_cap_exceeded", () => {
		const c = copyFor("notes_cap_exceeded");
		expect(c.title).toMatch(/note limit/iu);
		expect(c.body).toBeTruthy();
	});

	it("maps attachments_disabled", () => {
		expect(copyFor("attachments_disabled").title).toMatch(/pro feature/iu);
	});

	it("falls back for unknown reason", () => {
		expect(copyFor("zzz_unknown").title).toMatch(/limit reached/iu);
	});
});
