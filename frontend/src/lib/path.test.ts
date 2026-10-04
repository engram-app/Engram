import { expect, test } from "vitest";
import { encodePathSegments } from "./path";

test("encodes each segment and keeps the slashes", () => {
	expect(encodePathSegments("My Docs/a b#1.png")).toBe("My%20Docs/a%20b%231.png");
	expect(encodePathSegments("plain.png")).toBe("plain.png");
});
