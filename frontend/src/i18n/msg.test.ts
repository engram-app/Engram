import { expect, it } from "vitest";
import { msg } from "./msg";

it("returns the English string unchanged", () => {
	expect(msg("Save changes")).toBe("Save changes");
	expect(msg("")).toBe("");
});
