import { toast } from "sonner";
import { beforeEach, describe, expect, expectTypeOf, it, vi } from "vitest";
import { untranslated } from "../i18n/ui-text";
import { notify } from "./notify";

vi.mock("sonner", () => ({
	toast: Object.assign(vi.fn(), { error: vi.fn(), success: vi.fn(), info: vi.fn() }),
}));

describe("notify", () => {
	beforeEach(() => vi.clearAllMocks());

	it("forwards to sonner, options included", () => {
		const text = untranslated("Saved");
		notify(text);
		notify.error(text, { id: "x" });
		notify.success(text);
		notify.info(text);
		expect(toast).toHaveBeenCalledWith(text, undefined);
		expect(toast.error).toHaveBeenCalledWith(text, { id: "x" });
		expect(toast.success).toHaveBeenCalledWith(text, undefined);
		expect(toast.info).toHaveBeenCalledWith(text, undefined);
	});

	it("only takes translated text, so a raw string fails tsc", () => {
		expectTypeOf(notify.error).parameter(0).not.toMatchTypeOf<string>();
		expectTypeOf<string>().not.toMatchTypeOf<Parameters<typeof notify.error>[0]>();
		expectTypeOf<string>().not.toMatchTypeOf<
			NonNullable<NonNullable<Parameters<typeof notify.error>[1]>["description"]>
		>();
	});
});
