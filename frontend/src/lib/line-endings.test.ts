import { describe, expect, it } from "vitest";
import { toLf } from "./line-endings";

describe("toLf", () => {
	it("converts CRLF, a lone CR and mixed endings, CRLF as one newline", () => {
		expect(toLf("a\r\nb\rc\nd\r\r\ne")).toBe("a\nb\nc\nd\n\ne");
	});

	it("leaves LF text and the empty string alone", () => {
		expect(toLf("a\nb\n")).toBe("a\nb\n");
		expect(toLf("")).toBe("");
	});
});
