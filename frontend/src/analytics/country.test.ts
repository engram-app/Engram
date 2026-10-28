import { afterEach, describe, expect, it, vi } from "vitest";
import { reportCountry } from "./country";
import * as identity from "./identity";

afterEach(() => vi.restoreAllMocks());

const answer = (res: Response) => vi.spyOn(globalThis, "fetch").mockResolvedValue(res);

describe("reportCountry", () => {
	it("hands a valid country to identity", async () => {
		const spy = vi.spyOn(identity, "setCountry").mockImplementation(() => {});
		answer(Response.json({ country: "PT" }));
		await reportCountry("/ph");
		expect(spy).toHaveBeenCalledWith("PT");
	});

	it.each([
		["null country", Response.json({ country: null })],
		["lowercase", Response.json({ country: "pt" })],
		["gpc 204", new Response(null, { status: 204 })],
	])("ignores %s", async (_n, res) => {
		const spy = vi.spyOn(identity, "setCountry").mockImplementation(() => {});
		answer(res);
		await reportCountry("/ph");
		expect(spy).not.toHaveBeenCalled();
	});

	it("swallows a network failure", async () => {
		vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("offline"));
		await expect(reportCountry("/ph")).resolves.toBeUndefined();
	});
});
